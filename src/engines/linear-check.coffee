fs = require 'fs'
path = require 'path'
glob = require 'glob'
_ = require 'lodash'
katt = require '../katt'
blueprintParser = require 'katt-blueprint-parser'


GLOB_OPTIONS =
  nosort: true
  stat: false


module.exports = class LinearCheckEngine
  options: undefined
  _contexts: undefined
  _modifyContext: () ->

  constructor: (scenarios, options = {}) ->
    return new LinearCheckEngine(scenarios, options)  unless this instanceof LinearCheckEngine
    @scenariosByFilename = {}
    @_contexts =
      UID:
        UID: undefined
        scenario: undefined
        operationIndex: undefined
        vars: undefined
    @options = _.merge options, {
      default:
        scenario: undefined
        operation: 0
      hooks:
        preSend: undefined
        postSend: undefined
      check:
        url: true
        method: true
        headers: true
        body: true
    }
    @server =
      hostname: options.hostname
      port: options.port
    @loadScenarios scenarios


  loadScenario: (filename) ->
    try
      blueprint = katt.readScenario filename
    catch e
      throw new Error "Unable to find/parse blueprint file #{filename}\n#{e}"
    @scenariosByFilename[filename] = {
      filename
      blueprint
    }


  loadScenarios: (scenarios) ->
    for scenario in scenarios
      continue  unless fs.existsSync scenario
      scenario = path.normalize scenario

      if fs.statSync(scenario).isDirectory()
        apibs = glob.sync "#{scenario}/**/*.apib", GLOB_OPTIONS
        @loadScenarios apibs
      else if fs.statSync(scenario).isFile()
        @loadScenario scenario


  middleware: (req, res, next) =>
    # Check for scenario filename
    scenarioFilename = req.cookies.katt_scenario or= @options.default.scenario

    unless scenarioFilename
      res.clearCookie 'katt_scenario', path: '/'
      res.clearCookie 'katt_operation', path: '/'
      return @sendError res, 500, 'Please define a scenario'

    UID = req.sessionID + " # " + scenarioFilename
    context = req.context = @_contexts[UID] or (@_contexts[UID] = {
      UID
      scenario: undefined
      operationIndex: 0
      vars: {}
    })

    # Check for scenario
    context.scenario = scenario = @scenariosByFilename[scenarioFilename]
    unless scenario?
      return @sendError res, 500, "Unknown scenario with filename #{scenarioFilename}"

    # FIXME this is not really the index, it's the reference point (the last operation step), so please rename
    currentOperationIndex = context.operationIndex or 0
    # Check for operation index
    req.cookies.katt_operation or= @options.default.operation or 0
    context.operationIndex = parseInt req.cookies.katt_operation, 10

    # Check if we're FFW operations
    if context.operationIndex > currentOperationIndex
      mockedOperationIndex = context.operationIndex - 1
      for operationIndex in [currentOperationIndex..mockedOperationIndex]
        context.operationIndex = operationIndex
        mockRes = @_mockPlayOperationIndex req, res

        return @sendError res, mockRes.statusCode, mockRes.body  if mockRes.getHeader 'x-katt-error'

        nextOperationIndex = context.operationIndex + 1
        logPrefix = "#{context.scenario.filename}\##{nextOperationIndex}"
        operation = context.scenario.blueprint.operations[nextOperationIndex - 1]

        # Validate response, so that we can continue with the request
        result = []
        @validateResponse mockRes, operation.request, context.vars, result
        if result.length
          result = JSON.stringify result, null, 2
          return @sendError res, 403, "#{logPrefix} < Response does not match\n#{result}"

        # Remember mockRes cookies for next request
        do () ->
          for key, value of mockRes.cookies
            req.cookies[key] = value

      context.operationIndex = mockedOperationIndex + 1

    # Play
    @_playOperationIndex req, res


  _mockPlayOperationIndex: (req, res) ->
    context = req.context

    finalRes = undefined

    mockReq = _.pick req, 'context', 'sessionID', 'cookies'

    nextOperationIndex = context.operationIndex + 1
    logPrefix = "#{context.scenario.filename}\##{nextOperationIndex}"
    operation = context.scenario.blueprint.operations[nextOperationIndex - 1]
    unless operation
      return @sendError res, 403,
        "Operation #{nextOperationIndex} has not been defined in blueprint file for #{context.scenario.filename}"

    mockReq.method = operation.request.method
    mockReq.url = @recallDeep operation.request.url, context.vars
    mockReq.headers = @recallDeep(operation.request.headers, context.vars) or {}
    mockReq.body = @recallDeep operation.request.body, context.vars
    # FIXME special treat for cookies (sync req.cookies with Cookie header)

    mockRes = {
      statusCode: undefined
      headers: {}
      cookies: {}
      body: undefined
      status: () ->                 mockRes.statusCode
      getHeader: (header) ->        mockRes.headers[header.toLowerCase()]
      setHeader: (header, value) -> mockRes.headers[header.toLowerCase()] = value
      cookie: (key, value) ->
        mockRes.cookies[key] = value
      #write: () ->
      end: () ->
      send: (statusCode, body) ->
        return  if finalRes # or throw error ?
        if typeof statusCode is 'number'
          res.statusCode = statusCode
        else
          # no statusCode sent, just maybe body
          body = statusCode
        res.body = body
        finalRes = res
    }

    @_playOperationIndex mockReq, mockRes

    finalRes


  _playOperationIndex: (req, res) ->
    context = req.context

    @_modifyContext req, res

    nextOperationIndex = context.operationIndex + 1
    logPrefix = "#{context.scenario.filename}\##{nextOperationIndex}"
    operation = context.scenario.blueprint.operations[nextOperationIndex - 1]
    unless operation
      return @sendError res, 403,
        "Operation #{nextOperationIndex} has not been defined in blueprint file for #{context.scenario.filename}"

    context.operationIndex = nextOperationIndex

    result = []
    @validateRequest req, operation.request, context.vars, result
    if result.length
      result = JSON.stringify result, null, 2
      return @sendError res, 403, "#{logPrefix} < Request does not match\n#{result}"

    res.cookie 'katt_scenario', context.scenario.filename, path: '/'
    res.cookie 'katt_operation', context.operationIndex, path: '/'

    headers = @recallDeep(operation.response.headers, context.vars) or {}
    res.body = @recallDeep operation.response.body, context.vars

    res.status operation.response.status
    res.setHeader header, headerValue  for header, headerValue of headers

    @callHook 'preSend', req, res, () =>
      res.body = JSON.stringify(res.body, null, 4)  if katt.isJsonBody res
      res.send res.body
      @callHook 'postSend', req, res

    true


  recallDeep: (value, vars) =>
    if _.isString value
      value = value.replace /{{>/g, '{{<'
      katt.recall value, vars
    else
      value[key] = @recallDeep value[key], vars  for key in _.keys value
      value


  callHook: (name, req, res, next = ->) ->
    if @options.hooks[name]?
      @options.hooks[name] req, res, next
    else
      next()


  sendError: (res, statusCode, error) ->
    res.setHeader 'Content-Type', 'text/plain'
    res.setHeader 'X-KATT-Error', 'true'
    res.send statusCode, error


  validateReqRes: (actualReqRes, expectedReqRes, vars = {}, result = []) ->
    headerResult = []
    headersResult = @options.check.headers ? katt.validateHeaders actualReqRes.headers, expectedReqRes.headers, vars
    result = result.concat headersResult  if headersResult.length

    actualRequestBody = katt.maybeJsonBody actualReqRes
    bodyResult = []
    bodyResult = @options.check.body ? katt.validateBody actualReqResBody, expectedReqRes.body, vars
    result = result.concat bodyResult  if bodyResult.length

    result


  validateRequest: (actualRequest, expectedRequest, vars = {}, result = []) ->
    urlResult = []
    urlResult = @options.check.url ? katt.validate 'url', actualRequest.url, expectedRequest.url, vars
    result = result.concat urlResult  if urlResult.length

    methodResult = []
    methodResult = @options.check.method ? katt.validate 'method', actualRequest.method, expectedRequest.method, vars
    result = result.concat methodResult  if methodResult.length

    @validateReqRes actualRequest, expectedRequest, vars, result

    result


  validateResponse: (actualResponse, expectedResponse, vars = {}, result = []) ->
    statusCodeResult = []
    statusCodeResult = katt.validate 'statusCode', actualResponse.statusCode, expectedResponse.statusCode, vars
    result = result.concat statusCodeResult  if statusCodeResult.length

    @validateReqRes actualResponse, expectedResponse, vars, result

    result
