###
   Copyright 2013 Klarna AB

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
###

fs = require 'fs'
path = require 'path'
url = require 'url'
glob = require 'glob'
_ = require 'lodash'
katt = require 'katt-js'
MockResponse = require '../mock-response'
MockRequest = require '../mock-request'


GLOB_OPTIONS =
  nosort: true
  stat: false


module.exports = class LinearCheckEngine
  options: undefined
  _contexts: undefined
  _playTransactionIndex_modifyContext: () ->
  _middleware_resolveTransactionIndex: (req, res, transactionIndex) -> transactionIndex


  constructor: (scenarios, options = {}) ->
    return new LinearCheckEngine(scenarios, options)  unless this instanceof LinearCheckEngine
    @scenariosByFilename = {}
    @_contexts =
      UID:
        UID: undefined
        scenario: undefined
        transactionIndex: undefined
        vars: undefined
    @options = _.merge options, {
      default:
        scenario: undefined
        transaction: 0
      hooks:
        preSend: undefined
        postSend: undefined
      check:
        url: true
        method: true
        headers: true
        body: true
    }
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
    scenarios = [scenarios]  unless _.isArray scenarios
    for scenario in scenarios
      continue  unless fs.existsSync scenario
      scenario = path.normalize scenario

      if fs.statSync(scenario).isDirectory()
        apibs = glob.sync "#{scenario}/**/*.apib", GLOB_OPTIONS
        @loadScenarios apibs
      else if fs.statSync(scenario).isFile()
        @loadScenario scenario


  middleware: (req, res, next) =>
    # FIXME better idea? proxies might rewrite the path
    if /katt_scenarios\.json/.test req.url
      @middleware_json req, res, next
    else
      @middleware_scenario req, res, next


  middleware_json: (req, res, next) ->
    res.setHeader 'Content-Type', 'application/json'
    res.body = JSON.stringify @scenariosByFilename, null, 2
    res.send 200, res.body


  middleware_scenario: (req, res, next) ->
    cookieScenario = req.cookies.katt_scenario or @options.default.scenario
    cookieTransaction = decodeURIComponent(req.cookies.katt_transaction) or @options.default.transaction
    [transactionIndex, resetToTransactionIndex] = "#{cookieTransaction}".split '|'

    # Check for scenario filename
    scenarioFilename = cookieScenario

    unless scenarioFilename
      res.cookies.katt_scenario = undefined
      res.cookies.katt_transaction = undefined
      return @sendError res, 500, 'Please define a scenario'

    sessionID = res.cookies.katt_session_id = req.cookies.katt_session_id or (new Date().getTime())

    UID = sessionID + " # " + scenarioFilename
    context = req.context = @_contexts[UID] ?= {
      UID
      scenario: undefined
      transactionIndex: 0
      vars: _.merge {}, @options.vars or {},
        katt.utils.parseHost req.headers.host
    }

    # Check for scenario
    context.scenario = scenario = @_findScenarioByFilename scenarioFilename
    unless scenario?
      return @sendError res, 500, "Unknown scenario with filename #{scenarioFilename}"

    transactionIndex = @_middleware_resolveTransactionIndex req, res, transactionIndex

    if _.isNaN(transactionIndex - 0) or (resetToTransactionIndex isnt undefined and _.isNaN(resetToTransactionIndex - 0))
      return @sendError res, 500, """
      Unknown transactions with filename #{scenarioFilename} - #{transactionIndex}|#{resetToTransactionIndex}
      """

    # FIXME this is not really the index, it's the reference point (the last transaction step), so please rename
    if resetToTransactionIndex?
      currentTransactionIndex = parseInt resetToTransactionIndex, 10
    else
      currentTransactionIndex = context.transactionIndex
    # Check for transaction index
    context.transactionIndex = parseInt transactionIndex, 10

    # FIXME if context.transactionIndex < currentTransactionIndex, then it means we went back in time
    # and it might be better to clear the context.vars

    # Check if we're FFW transactions
    if context.transactionIndex > currentTransactionIndex
      mockedTransactionIndex = context.transactionIndex - 1
      for transactionIndex in [currentTransactionIndex..mockedTransactionIndex]
        context.transactionIndex = transactionIndex
        mockResponse = @_mockPlayTransactionIndex req, res

        return @sendError res, mockResponse.statusCode, mockResponse.body  if mockResponse.getHeader 'x-katt-error'

        nextTransactionIndex = context.transactionIndex
        logPrefix = "#{context.scenario.filename}\##{nextTransactionIndex}"
        transaction = context.scenario.blueprint.transactions[nextTransactionIndex - 1]

        # Validate response, so that we can continue with the request
        result = []
        @validateResponse mockResponse, transaction.response, context.vars, result
        if result.length
          result = JSON.stringify result, null, 2
          return @sendError res, 403, "#{logPrefix} < Response does not match\n#{result}"

        # Remember mockResponse cookies for next request
        do () ->
          for key, value of mockResponse.cookies
            req.cookies[key] = value

      context.transactionIndex = mockedTransactionIndex + 1
      req.url = @recallDeep context.scenario.blueprint.transactions[nextTransactionIndex].request.url, context.vars

    # Play
    res.cookies['x-katt-dont-validate'] = ''  if req.cookies['x-katt-dont-validate']
    @_playTransactionIndex req, res


  _findScenarioByFilename: (scenarioFilename) ->
    scenario = @scenariosByFilename[scenarioFilename]
    return scenario  if scenario?
    for scenarioF, scenario of @scenariosByFilename
      endsWith = scenarioF.indexOf(scenarioFilename, scenarioF.length - scenarioFilename.length) isnt -1
      return scenario  if endsWith
    undefined


  _maybeSetContentLocation: (req, res) ->
    context = req.context
    transaction = context.scenario.blueprint.transactions[context.transactionIndex]

    return  unless transaction

    # maybe the request target has changed during the skipped transactions
    result = katt.validateUrl req.url, transaction.request.url, context.vars
    if result?[0]?[0] is 'not_equal'
      intendedUrl = result[0][3]
      res.setHeader 'content-location', intendedUrl


  _mockPlayTransactionIndex: (req, res) ->
    context = req.context

    mockRequest = new MockRequest req

    nextTransactionIndex = context.transactionIndex + 1
    logPrefix = "#{context.scenario.filename}\##{nextTransactionIndex}"
    transaction = context.scenario.blueprint.transactions[nextTransactionIndex - 1]
    unless transaction
      return @sendError res, 403,
        "Transaction #{nextTransactionIndex} has not been defined in blueprint file for #{context.scenario.filename}"

    mockRequest.method = transaction.request.method
    mockRequest.url = @recallDeep transaction.request.url, context.vars
    mockRequest.headers = @recallDeep(transaction.request.headers, context.vars) or {}
    mockRequest.body = @recallDeep transaction.request.body, context.vars
    # FIXME special treat for cookies (sync req.cookies with Cookie header)

    mockResponse = new MockResponse()

    @_playTransactionIndex mockRequest, mockResponse

    mockResponse


  _dontValidate: (req, res) ->
    header = req.headers['x-katt-dont-validate']
    cookie = req.cookies['x-katt-dont-validate']
    header or cookie


  _playTransactionIndex: (req, res) ->
    context = req.context

    @_playTransactionIndex_modifyContext req, res

    nextTransactionIndex = context.transactionIndex + 1
    logPrefix = "#{context.scenario.filename}\##{nextTransactionIndex}"
    transaction = context.scenario.blueprint.transactions[nextTransactionIndex - 1]
    unless transaction
      return @sendError res, 403,
        "Transaction #{nextTransactionIndex} has not been defined in blueprint file for #{context.scenario.filename}"

    context.transactionIndex = nextTransactionIndex

    if @_dontValidate req, res
      @_maybeSetContentLocation req, res
    else
      result = []
      @validateRequest req, transaction.request, context.vars, result
      if result.length
        result = JSON.stringify result, null, 2
        return @sendError res, 403, "#{logPrefix} < Request does not match\n#{result}"

    res.cookies.katt_scenario = context.scenario.filename
    res.cookies.katt_transaction = context.transactionIndex

    headers = @recallDeep(transaction.response.headers, context.vars) or {}
    res.body = @recallDeep transaction.response.body, context.vars

    res.statusCode = transaction.response.status
    res.setHeader header, headerValue  for header, headerValue of headers

    @callHook 'preSend', req, res, () =>
      res.body = JSON.stringify(res.body, null, 2)  if katt.utils.isJsonBody res
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


  callHook: (name, req, res, next) ->
    if @options.hooks[name]?
      @options.hooks[name] req, res, next
    else
      next()  if next?


  sendError: (res, statusCode, error) ->
    res.setHeader 'Content-Type', 'text/plain'
    res.setHeader 'X-KATT-Error', encodeURIComponent error.split('\n').shift()
    res.send statusCode, error


  validateReqRes: (actualReqRes, expectedReqRes, vars = {}, result = []) ->
    headerResult = []
    headersResult = katt.validateHeaders actualReqRes.headers, expectedReqRes.headers, vars  if @options.check.headers
    result.push.apply result, headersResult  if headersResult.length

    actualReqResBody = katt.utils.maybeJsonBody actualReqRes
    bodyResult = []
    bodyResult = katt.validateBody actualReqResBody, expectedReqRes.body, vars  if @options.check.body
    result.push.apply result, bodyResult  if bodyResult.length

    result


  validateRequest: (actualRequest, expectedRequest, vars = {}, result = []) ->
    methodResult = []
    methodResult = katt.validate 'method', actualRequest.method, expectedRequest.method, vars  if @options.check.method
    result.push.apply result, methodResult  if methodResult.length

    urlResult = []
    urlResult = katt.validateUrl actualRequest.url, expectedRequest.url, vars
    result.push.apply result, urlResult  if urlResult.length

    @validateReqRes actualRequest, expectedRequest, vars, result

    result


  validateResponse: (actualResponse, expectedResponse, vars = {}, result = []) ->
    statusResult = []
    statusResult = katt.validate 'status', actualResponse.statusCode, expectedResponse.status, vars
    result.push.apply result, statusResult  if statusResult.length

    @validateReqRes actualResponse, expectedResponse, vars, result

    result
