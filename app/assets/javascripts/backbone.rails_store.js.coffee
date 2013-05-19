###
*  Copyright (C) 2013 - Raphael Derosso Pereira <raphaelpereira@gmail.com>
*
*  Backbone.RailsStore - version 1.0.12
*
*  Backbone extensions to provide complete Rails interaction on CoffeeScript/Javascript,
*  keeping single reference models in memory, reporting refresh conflicts and consistently
*  persisting models and there relations.
*
*  Backbone.RailsStore may be freely distributed under the MIT license.
*
###

unless Backbone.CollectionSubset
  throw 'Backbone.RailsStore depends upon Backbone.CollectionSubset!'

unless Date.CultureInfo
  throw 'Backbone.RailsStore depends upon Datejs. Please load any Cultural version!'

###
* Backbone.RailsStore - Singleton Pattern Local Object/Collection Repository
*
* MUST be taken using Backbone.RailsStore.getInstance()
*
* Responsible to guarantee we have only one reference to each Backbone.RailsModel!
* This has some implications on memory usage and server synchronization, but it at
* least guarantee consistency for some time.
###
class Backbone.RailsStore
  _defaultFormats:
    DateTime: 'dd/MM/yyyy HH:mm:ss'
    Date: 'dd/MM/yyyy'
    Boolean: ['Não', 'Sim']
  _dateFormats: [
    'yyyy-MM-dd',
    'd/M/yyyy','dd/M/yyyy','d/MM/yyyy','dd/MM/yyyy',
    'd-M-yyyy','dd-M-yyyy','d-MM-yyyy','dd-MM-yyyy',
    'd/M/yy','dd/M/yy','d/MM/yy', 'dd/MM/yy',
    'd-M-yy','dd-M-yy','d-MM-yy', 'dd-MM-yy'
  ]
  _types: {}
  _collections: {}
  _collectionsByModel: {}
  _instance: null
  _changedModels: {}
  _deletedModels: []
  _searchedModels: {_cid: 1}
  _synching: false
  _syncModels: []
  _refreshInterval: 10000
  _storeServer: null
  _refreshIntervalObj: null
  _progressElement: null
  _progressCounter: 0
  _manyToManyCreate: {}
  _manyToManyDestroy: {}
  _requests: []

  ###
    Singleton Pattern
  ###
  @getInstance: ->
    unless @_instance
      @_instance = new Backbone.RailsStore()
    return @_instance

  ###
    constructor - Add events and create communication model
  ###
  constructor: ->
    _.extend(@, Backbone.Events)
    @_storeServer = new Backbone.RailsStoreServer()
    @setBuiltinModifiersFormat(@_defaultFormats)

  ###
    setupProgressElement - Sets up a progress to be shown and hidden on communication
  ###
  setupProgressElement: (el) ->
    @_progressElement = el
    el.hide()

  ###
    setBuiltinModifiersFormat - Sets the default formats for builtin attributeModifiers
  ###
  setBuiltinModifiersFormat: (format) ->
    @_defaultFormats = format

  ###
    getBuiltinModifierFormat - returns the actual default format
  ###
  getBuiltinModifierFormat: (modifier) ->
    return @_defaultFormats[modifier]

  ###
    getDateFormats - returns formats to parse string to dates
  ###
  getDateFormats: ->
    return @_dateFormats

  ###
    setDateFormats - sets the accepted date formats to parse from strings
  ###
  setDateFormats: (formats) ->
    @_dateFormats = formats

  ###
    findById - Returns internal reference to object by its ID or CID
  ###
  findById: (type, id) ->
    col = @getCollectionFromModel(type)
    return col.get(id)


  ###
    release - remove model from Store and (try) to free memory

    After calling release, the model instance will not be used anymore.
    If summond, model will be constructed from server data
  ###
  release: (model, options) ->
    col = @getCollectionFromModel(model)
    col.remove(model,options)
    modelType = @getModelType(model)
    @_changedModels[modelType] = _.without(@_changedModels[modelType], model) if @_changedModels[modelType]
    @_deletedModels = _.without(@_deletedModel, model) if @_deletedModels
    modelId = model.id if model.id
    modelId = model.cid unless model.id
    if @_manyToManyCreate[modelType] and @_manyToManyCreate[modelType][modelId]
      delete @_manyToManyCreate[modelType][modelId]
    if @_manyToManyDestroy[modelType] and @_manyToManyDestroy[modelType][modelId]
      delete @_manyToManyDestroy[modelType][modelId]

  ###
    releaseAll - Free RailsStore from all models informations except models marked as persistent
  ###
  releaseAll: ->
    hasElements = true
    while hasElements
      hasElements = false
      _.each @_collections, (collection) =>
        collection.each (model) =>
          unless model.isPersistent()
            hasElements = true
            @release(model, {silent:true})

    _.each @_requests, (xhr) =>
      xhr.abort()
    @_requests.length = 0
    @_changedModels = {}
    @_deletedModels = []
    @_manyToManyCreate = {}
    @_manyToManyDestroy = {}
    @_searchedModels = {_cid: 1}

  ###
    authenticate - Performs server authentication

    Parameters:
      success - callback function upon success [opt]
      error - callback function upon error [opt]
      modelType - rails model to be used as authentication model
      model - RailsModel instance with authentication data

    Triggers:
      authenticate:done - upon success
      authenticate:failed - upon failure
  ###
  authenticate: (options) ->
    unless options.modelType
      throw('Must define a modelType upon authentication!')
    unless options.model
      throw('Must define a model upon authentication')
    options.modelType = @getModelType(options.modelType)
    token = (new Date()).toString()
    hash = Sha1.hash("#{token}#{options.model.get('password')}")
    request =
      railsClass: options.modelType
      model:
        login: options.model.get('login')
        token: token
        hash: hash

    @_storeServer.urlRoot = @_storeServer.authUrlRoot
    xhr = @_storeServer.fetch
      data: $.param({authModel: request})
      type: 'POST'
      storeSync: true
      silent: true
      success: (model, resp) =>
        try
          if model.get('errors') or not model.get('authModel')
            @trigger('authenticate:failed')
            options.error() if options.error
            return
          @_processServerModelsResponse(model)
          @_processServerRelationsResponse(model)
          @reportSyncChanges()
          authModelData = model.get('authModel')
          model.unset('authModel')
          authModel = @findById(authModelData.railsClass, authModelData.id)
          @trigger('authenticate:done', authModel)
          options.success(authModel) if options.success
        catch e
          console.log(e)
          @trigger('comm:fatal', e)
          options.error() if options.error
          @trigger('authenticate:failed')
          throw e
      error: =>
        options.error() if options.error
        @trigger('authenticate:failed')
    @_doProgress(xhr)


  ###
    findRemote - Perform server call asking for specific model data

    Parameters:
      modelType - rails model to be used as main search class
      searchParams - data to be passed to Model.rails_store_search class in rails
      limit - max number of registers [opt]
      page - first page (considering max registers in each page. Begins in 1 not 0) [opt]
      success - callback function upon success [opt]
      error - callback function upon error [opt]

    Trigger:
      find:start - just after server request
      find:done - upon completion
      find:exists - upon completion with valid results
      find:empty - upon completion with no valid results
      find:failed - upon error
      page:loaded - after a <any>Page() request completed
      page:failed - upon a <any>Page() request completed

    Returns:
      Releaseable collection that will be updated upon server response. In case
      limit/page is used, collection also implements the following methods:
      maxLength() - total records in database
      pages() - return the total number of pages
      actualPage() - return actual page number
      nextPage() - request next page models from server
      previousPage() - request previous page models from server
      firstPage() - request first page models from server
      lastPage() - request last page models from server
  ###
  findRemote: (options) ->
    unless options.modelType
      throw('Must define a modelType upon search!')
    options.modelType = @getModelType(options.modelType)
    col_cid = @_searchedModels._cid++
    @_searchedModels[options.modelType] = {} unless @_searchedModels[options.modelType]
    @_searchedModels[options.modelType][col_cid] =
      subset: null
      ids: []

    @_searchedModels[options.modelType][col_cid].subset = new Backbone.RailsSearchResultCollection
        parent: @getCollectionFromModel(options.modelType)
        filterData: @_searchedModels[options.modelType][col_cid].ids
        modelType: options.modelType
        cid: col_cid
        pageData: {ids:[], actualPage: 1, pages: 1, pageSize: 0}

    request =
      modelType: options.modelType
      railsClass: @_getModelTypeObj(options.modelType).prototype.railsClass
      searchParams: options.searchParams
      limit: options.limit
      page: options.page

    @_storeServer.urlRoot = @_storeServer.findUrlRoot
    xhr = @_storeServer.fetch
      data: $.param({searchModels: request})
      type: 'POST'
      storeSync: true
      silent: true
      success: (model, resp) =>
        try
          searchTarget = null
          if @_searchedModels[options.modelType]
            if @_searchedModels[options.modelType][col_cid]
              searchTarget = @_searchedModels[options.modelType][col_cid]
          reportExists = false
          @_processServerModelsResponse(model)
          @_processServerRelationsResponse(model)
          @reportSyncChanges()
          pageData = model.get('pageData')[options.modelType]
          if pageData and searchTarget
            searchTarget.subset.pageData = pageData
            if pageData.pageSize > 0
              firstId = (pageData.actualPage-1)*pageData.pageSize
              lastId = (pageData.actualPage)*pageData.pageSize
              pageObjIds = pageData.ids.slice(firstId,lastId)
            else
              pageObjIds = pageData.ids
            _.each pageObjIds, (id) =>
              m = @findById(options.modelType, id)
              searchTarget.ids.push(m.cid)
          searchTarget.subset.refresh() if searchTarget
          model.unset('pageData')
          if options.success and searchTarget
            options.success(searchTarget.subset.child)
          @trigger('find:exists', @) if reportExists
          @trigger('find:empty',@) unless reportExists
          @trigger('find:done', @)
        catch e
          console.log(e)
          @trigger('comm:fatal', e)
          if options.error
            options.error.apply(@,arguments)
          @trigger('find:failed', @)
          throw e
      error: =>
        if options.error
          options.error.apply(@,arguments)
        @trigger('find:failed', @)

    @trigger('find:start', @)
    @_doProgress(xhr)
    return @_searchedModels[options.modelType][col_cid].subset.child

  ###
    commit - persist changes to server

    Persists all changes to server and performs a sync after that

    Parameters:
      success - Called upon success
      error - Called upon error

    Triggers:
      commit:start - just after starting server request
      commit:done - after successful server request response
      commit:failed - if something wrong happened
  ###
  commit: (options) ->
    options = options || {}
    commitData = {}
    _.each @_changedModels, (models, modelType) =>
      _.each models, (model) =>
        commitData[modelType] = {railsClass: model.railsClass, data: []} unless commitData[modelType]
        commitData[modelType].data.push(model.toJSON())

    destroyData = {}
    _.each @_deletedModels, (model) =>
      modelType = @getModelType(model)
      destroyData[modelType] = [] unless destroyData[modelType]
      destroyData[modelType].push(model.toJSON())

    createRelationData = @_manyToManyCreate
    destroyRelationData = @_manyToManyDestroy

    @_storeServer.urlRoot = @_storeServer.commitUrlRoot
    @_storeServer.set('commitModels', commitData)
    @_storeServer.set('destroyModels', destroyData)
    @_storeServer.set('createRelations', createRelationData)
    @_storeServer.set('destroyRelations', destroyRelationData)
    xhr = @_storeServer.save null,
      silent: true
      storeSync: true
      success: (model) =>
        try
          # Treat errors
          errors =  model.get('errors')
          if errors
            modelType = @getModelType(errors.railsClass)
            model = @_storeLocally(modelType, errors.model)
            model.dirty = true unless model.id
            errors = errors.errors
            model.trigger 'commit:failed',
              model: model,
              errors: errors
          else
            triggerModels = []
            _.each @_changedModels, (changedModels, modelType) =>
              _.each changedModels, (changedModel) =>
                triggerModels.push(changedModel)
            _.each model.get('modelsIds'), (idsData, modelType) =>
              _.each idsData, (id, cid) =>
                storedModel = @findById(modelType, cid)
                unless storedModel
                  throw "Didn't find local model with cid! API BUG!"
                storedModel.set('id', id)
                @reportSync(storedModel)
            @_processServerModelsResponse(model, {noConflict: true})
            @_processServerRelationsResponse(model)
            @_changedModels = {}
            @_deletedModels.length = 0
            @_manyToManyCreate = {}
            @_manyToManyDestroy = {}

          @_storeServer.unset('commitModels')
          @_storeServer.unset('destroyModels')
          @_storeServer.unset('modelsIds')
          @_storeServer.unset('createRelations')
          @_storeServer.unset('destroyRelations')
          @_storeServer.unset('models')
          @_storeServer.unset('errors')
          _.each triggerModels, (changedModel) =>
            changedModel.trigger 'commit:done', changedModel
          @trigger('commit:done', @) unless errors
          @trigger('commit:failed', {model: model, errors: errors}) if errors
          options.success() if options.success and not errors
          options.error(errors) if options.error and errors
          # TODO: handle rollback
        catch e
          console.log(e)
          @trigger('comm:fatal', e)
          @trigger('commit:failed', {errors: "Communication error!"})
          throw e
      error: =>
        # TODO: i18n
        errors = {errors: "Communication error!"}
        options.error(errors) if options.error
        @trigger('commit:failed', errors)

    @trigger('commit:start')
    @_doProgress(xhr)


  ###
    refresh - updates models with a server version

    In case changes comes from server that would apply to local changed
    models, avoid update and triggers a general 'refresh:conflict' and specific
    'refresh:conflict:attribute' according to models conflicting atrribute

    After all is done, 'refresh:done' is triggered

    Options:
      models - models to be refreshed
      modelsIds - array of hashes (or single hash) with railsClass and ids attributes
      relations - relations to be refreshed
      success - method to be called upon success [opt]

    Events:
      refresh:start - just after initiating server request
      refresh:done  - after server request success response
      refresh:conflict - after server request success, but with attributes conflict detection
      refresh:conflict:<attribute> - triggered on conflicted model
      refresh:failed
  ###
  refresh: (options) ->
    options = {} unless options
    success = options.success
    models = options.models
    modelsIds = options.modelsIds
    relations = options.relations
    if models
      models = [models] unless _.isArray(models)
      request = {}
      _.each models, (model) =>
        return unless model.id
        modelType = @getModelType(model)
        unless request[modelType]
          request[modelType] =
          railsClass: model.railsClass
          ids: []
        request[modelType].ids.push(model.id)

    if modelsIds
      request = {}
      modelsIds = [modelsIds] unless _.isArray(modelsIds)
      _.each modelsIds, (modelIds) =>
        _.each modelIds, (data, modelType) =>
          unless request[modelType]
            request[modelType] =
              railsClass: data.railsClass
              ids: []
          request[modelType].ids = request[modelType].ids.concat(data.ids)

    unless request or relations
      request = {}
      _.each @_collections, (collection) =>
        collection.each (model) =>
          return unless model.id
          modelType = @getModelType(model)
          unless request[modelType]
            request[modelType] =
              railsClass: model.railsClass
              ids: []
          request[modelType].ids.push(model.id)

    request = {refreshModels: request} if request
    request = {} unless request
    request.relations = relations if relations

    if _.size(request.refreshModels) == 0 and _.size(request.relations) == 0
      @trigger('refresh:start')
      @trigger('refresh:done')
      return

    @_storeServer.urlRoot = @_storeServer.fetchUrlRoot
    xhr = @_storeServer.fetch
      data: $.param(request)
      type: 'POST'
      storeSync: true
      silent: true
      success: (model, resp, options) =>
        try
          @_processServerModelsResponse(model)
          @_processServerRelationsResponse(model)
          @reportSyncChanges()
          @trigger('refresh:done', @)
          success() if success
        catch e
          console.log(e)
          @trigger('comm:fatal', e)
          @trigger('refresh:failed')
          throw e
      error: ->
        @trigger('refresh:failed')

    @trigger('refresh:start')
    @_doProgress(xhr)

  ###
    service - Provides others controllers call

    Parameters:
      url - URL to be used in call
      models - Model to send to controller
      params - Other parameters to send to controller
      type - Type of call. Defaults to 'POST'
      success - method to be executed upon sucess

    Response - This method accepts responses with the following data:
      json - json data to be sent to success and trigger
      models - Models to be stored locally
      relations - Models hasOne and hasAndBelongsToMany relations

    Events:
      service:start - just after calling server controller
      service:done - upon successful call
      service:failed - upon failed call
  ###
  service: (params) ->
    throw "Must provide url parameter" unless params.url
    params.type = 'POST' unless params.type
    type = params.type
    @_storeServer.urlRoot = params.url
    request = {}
    request['models'] = params.models if params.models
    request['params'] = params.params if params.params
    xhr = @_storeServer.fetch
      data: $.param(request)
      type: type
      storeSync: true
      silent: true
      success: (model) =>
        try
          if model.get('models') or model.get('relations')
            models = {}
            @_processServerModelsResponse model,
              extra: (m) =>
                modelType = @getModelType(m)
                unless models[modelType]
                  models[modelType] = []
                models[modelType].push(m)
            @_processServerRelationsResponse(model)
            @reportSyncChanges()
            @trigger('service:done', models)
            params.success(models) if _.isFunction(params.success)
          else if model.get('json')
            resp = model.get('json')
            @trigger('service:done', resp)
            params.success(resp) if _.isFunction(params.success)
        catch e
          console.log(e)
          @trigger('comm:fatal', e)
          @trigger('service:failed', e)
          throw e
      error: (resp) =>
        @trigger('service:failed', resp)
    @trigger('service:start', @)
    @_doProgress(xhr)

  ###
    Reserved methods
  ###
  registerType: (type) ->
    modelType = @getModelType(type)
    @_types[modelType] = type;

    if type.collection
      @registerCollection(type.collection)

  registerCollection: (col) ->
    col_idx = @getModelType(col)
    unless @_collections[col_idx]
      new_col = new col()
      @_collections[col_idx] = new_col
      modelType = @getModelType(new_col)
      @_collectionsByModel[modelType] = new_col

  registerModel: (model,options) ->
    col_idx = @getModelType(model)
    col = @_collectionsByModel[col_idx]
    unless col?
      throw "No Collections for type #{col_idx}"
    col.add(model,options)
    @listenTo model, 'change', (model) => @_registerModelChange(model)

  registerDestroyRequest: (model) ->
    @stopListening model
    if model.id
      @_deletedModels.push(model)
    modelType = @getModelType(model)
    if @_changedModels[modelType]
      @_changedModels[modelType] = _.without(@_changedModels[modelType], model)


  reportSync: (model) ->
    model.syncAttributes = _.clone(model.attributes)
    #@_syncModels.push(model)
    modelType = @getModelType(model)
    @_changedModels[modelType] = _.without(@_changedModels[modelType], model)
    delete @_changedModels[modelType] if @_changedModels[modelType].length == 0

  reportSyncChanges: ->
    return

  getModelType: (model) ->
    if _.isString(model)
      unless @_types[model]
        throw "Invalid model #{model}"
      return model
    else if model instanceof Backbone.RailsModel
      return model.railsClass
    else if model instanceof Backbone.RailsCollection
      return model.model.prototype.railsClass
    else
      unless model.prototype.railsClass
        if model.prototype.model or not model.prototype.model.prototype.railsClass
          return  model.prototype.model.prototype.railsClass
        throw "Invalid model #{model}"
      return model.prototype.railsClass


  ###
  ###
  getCollectionFromModel: (model) ->
    klass = @getModelType(model)
    return @_collectionsByModel[klass]

  ###
    reportManyToManyEvent - Report ManyToMany association includes or removals

    Options:
      add - relations to be added
      remove - relations to be erased

      Options are hash in the following format:
      User:
        1:
          Role:
            [c1,2]
        c2:
          Role:
            [c1,3]
  ###
  reportManyRelationEvent: (options) ->
    if options.add
      _.each options.add, (sources, sourceType) =>
        _.each sources, (relations, sourceId) =>
          _.each relations, (ids, relationType) =>
            sourceRailsClass = @_getModelTypeObj(sourceType).prototype.railsClass
            @_manyToManyCreate[sourceType] = {railsClass: sourceRailsClass, models: {}} unless @_manyToManyCreate[sourceType]
            @_manyToManyCreate[sourceType].models[sourceId] = {} unless @_manyToManyCreate[sourceType].models[sourceId]
            @_manyToManyCreate[sourceType].models[sourceId][relationType] = {railsClass: ids.railsClass, ids: []} unless @_manyToManyCreate[sourceType].models[sourceId][relationType]
            obj = @_manyToManyCreate[sourceType].models[sourceId][relationType]
            obj.ids = _.uniq(obj.ids.concat(ids.ids))
            if @_manyToManyDestroy[sourceType] and @_manyToManyDestroy[sourceType].models[sourceId] and @_manyToManyDestroy[sourceType].models[sourceId][relationType]
              @_manyToManyDestroy[sourceType].models[sourceId][relationType].ids = _.difference(@_manyToManyDestroy[sourceType].models[sourceId][relationType].ids, ids.ids)

    if options.remove
      _.each options.remove, (sources, sourceType) =>
        _.each sources, (relations, sourceId) =>
          _.each relations, (ids, relationType) =>
            sourceRailsClass = @_getModelTypeObj(sourceType).prototype.railsClass
            @_manyToManyDestroy[sourceType] = {railsClass: sourceRailsClass, models: {}} unless @_manyToManyDestroy[sourceType]
            unless _.isFunction(sourceId.indexOf) and sourceId.indexOf('c') != -1
              @_manyToManyDestroy[sourceType].models[sourceId] = {} unless @_manyToManyDestroy[sourceType].models[sourceId]
              obj = @_manyToManyDestroy[sourceType].models[sourceId][relationType] = {railsClass: ids.railsClass, ids: []} unless @_manyToManyDestroy[sourceType].models[sourceId][relationType]
              obj = @_manyToManyDestroy[sourceType].models[sourceId][relationType]
              removeFromServer = []
              _.each ids.ids, (id) =>
                removeFromServer.push(id) unless _.isFunction(id.indexOf) and id.indexOf('c') != -1
              obj.ids = _.uniq(obj.ids.concat(removeFromServer))
            if @_manyToManyCreate[sourceType] and @_manyToManyCreate[sourceType].models[sourceId] and @_manyToManyCreate[sourceType].models[sourceId][relationType]
              @_manyToManyCreate[sourceType].models[sourceId][relationType].ids = _.difference(@_manyToManyCreate[sourceType].models[sourceId][relationType].ids, ids.ids)


  ###
    releaseSearchCollection - remove search collection from memory
  ###
  releaseSearchCollection: (collection) ->
    unless collection instanceof Backbone.RailsSearchResultCollection
      throw "Cannot release colllection! API BUG!"

    modelType = @getModelType(collection.modelType)
    delete @_searchedModels[modelType][collection.cid] if @_searchedModels[modelType]

  _doProgress: (xhr) ->
    @_requests.push(xhr)
    if @_progressCounter <= 0 and @_progressElement
      @_progressElement.show()
    @_progressCounter++
    xhr.always =>
      @_requests = _.without(@_requests, xhr)
      @_progressCounter--
      if @_progressCounter <= 0
        @_progressCounter = 0
        @_progressElement.hide() if @_progressElement

  _processServerModelsResponse: (model, options) ->
    options = options || {}
    _.each model.get('models'), (modelsData, modelType) =>
      _.each modelsData, (model) =>
        m = @_storeLocally(modelType, model, options)
        options.extra(m) if _.isFunction(options.extra)
    model.unset('models')

  _processServerRelationsResponse: (model) ->
    _.each model.get('relations'), (relationsData, modelType) =>
      _.each relationsData, (relationData, relationType) =>
        _.each relationData.models, (relationIds, modelId) =>
          owner = @findById(modelType, modelId)
          owner.set(relationData.attribute, relationIds)
    model.unset('relations')

  _storeLocally: (modelType, model, options) ->
    options = options || {}
    storedModel = @findById(modelType, model.id)
    unless storedModel
      serverModel = new @_types[modelType]({id: model.id}, {silent:true})
      serverModel.set(model, {parse:true, storeSync:true, silent:true})
      serverModel.trigger('change', serverModel)
      @reportSync(serverModel)
      serverModel.trigger('refresh:done', serverModel)
      return serverModel
    else
      # Must check if conflicts
      serverData = storedModel.parse(model)
      syncAttr = storedModel.syncAttributes
      serverChangedAttr = storedModel.syncChangedAttributes(serverData)
      localChangedAttr = storedModel.syncChangedAttributes(storedModel.attributes)
      if serverChangedAttr and localChangedAttr and not options.noConflict
        conflictKeys = _.keys(localChangedAttr)
        conflictChangedAttr = _.pick(serverChangedAttr, conflictKeys)
        noConflictAttr = _.omit(serverChangedAttr, conflictKeys)
        storedModel.conflict = conflictChangedAttr
        hasConflict = false
        _.each(conflictChangedAttr, (value, key) =>
          hasConflict = true
          storedModel.trigger("refresh:conflict:#{key}", storedModel)
        )
        storedModel.set(noConflictAttr,{storeSync:true, silent:true})
        storedModel.trigger('change', storedModel)
        @reportSync(storedModel)
        storedModel.syncAttributes = _.extend(syncAttr, noConflictAttr)
        if hasConflict
          storedModel.trigger("refresh:conflict", storedModel)
          return storedModel
        else
          delete storedModel.conflict
      else if serverChangedAttr
        storedModel.set(serverChangedAttr, {storeSync:true, silent:true})
        storedModel.trigger('change', storedModel)
      @reportSync(storedModel)

      storedModel.trigger('refresh:done', storedModel)
      return storedModel

  _getModelTypeObj: (model) ->
    type = @getModelType(model)
    return @_types[type]

  _registerModelChange: (model) ->
    unless model.railsClass
      return false
    modelType = @getModelType(model)
    unless _.isEqual model.syncAttributes, model.attributes
      @_changedModels[modelType] = [] unless @_changedModels[modelType]
      @_changedModels[modelType].push(model)
      @_changedModels[modelType] = _.uniq(@_changedModels[modelType])
    return model





###
* Backbone.RailsModel - Rails-like relations on top of Backbone
*
*  The heart and purpose of all this shit!
*
*  This has been made focusing Rails 3.2
*
###
class Backbone.RailsModel extends Backbone.Model
  _toJSONLock: false
  _persistent: false
  _readOnly: false

  ###
    Internal store reference
  ###
  _store: null

  ###
    belongsTo - Relations where reference resides in this object

    Format example - User of a Comment:
    belongsTo:
      user: -> CommentClass
  ###
  belongsTo: {}


  ###
    hasOne - Relations where reference resides elsewhere

    Format example - Last User Comment:
    hasOne:
      last_comment: -> CommentClass
  ###
  hasOne: {}


  ###
    hasMany - Relations where reference resides on other objects

    Format example - Comments of a User:
    hasMany:
      comments:
        modelType: -> CommentClass
        attribute: 'user'
  ###
  hasMany: {}


  ###
    hasAndBelongsToMany - Relations where references resides on different tables

    Format example - Users favorite Blogs
    hasAndBelongsToMany:
      blogs:
        modelType: -> BlogClass
        relationAttribute: users

    if relationAtrribute is optional. It should be used when relation is defined on
    both models so updated generated on one model is persisted on other
  ###
  hasAndBelongsToMany: {}

  ###
    attributeModifiers - Defines standard modifiers for attributes

    Usage:
      attributeModifiers is a Hash object on which each key stands for an
    attribute name associated with another hash with the following:

      getConverter - function to be called upon a get
      setConverter - function to be called upon a set
      converter    - function to be called upon set or get
      options      - options to be passed to converter

      Any converter (get, set or general) can be set to a builtin converter. Available builtins are:

      DateTime
      Date
      Boolean

      Builtin converters accepts a format option

  ###
  attributeModifiers: {}

  ###
    constructor - register model in Store and proceed
  ###
  constructor: (attr, options) ->
    _.extend @attributeModifiers,
      created_at:
        converter: 'DateTime'
      updated_at:
        converter: 'DateTime'
    _.each @attributeModifiers, (modifierData, type) =>
      if modifierData.converter
        @attributeModifiers[type].getConverter = modifierData.converter
        @attributeModifiers[type].setConverter = modifierData.converter

    @_store = Backbone.RailsStore.getInstance()
    super
    unless @attributes.created_at
      @set({created_at: new Date(),updated_at: new Date()},{silent:true})
    @_store.registerModel(@,options||{})
    @syncAttributes = {}
    unless @attributes.id
      @_store._registerModelChange(@)
    @syncAttributes = _.clone(@attributes)


  ###
    fetch - Request refresh from server
  ###
  fetch: (options) ->
    options.models = [@]
    success = options.success
    options.success = =>
      success(@) if success
    @_store.refresh options

  ###
    changedAttributes - override to treat relations
  ###
  changedAttributes: (attr) ->
    changedAttr = super
    if attr? and changedAttr
      _.each changedAttr, (value, key) =>
        # TODO: Should iterate over hasMany to check if it has changed
        if @belongsTo[key] or @hasOne[key] or @hasMany[key] or @hasAndBelongsToMany[key]
          delete changedAttr[key]
      changedAttr = false if _.isEmpty(changedAttr)
    return changedAttr

  ###
    setPersistent - change persistent model state

    Models marked as persistent are not released from Store upon releaseAll call
  ###
  setPersistent: (val) ->
    @_persistent = val?


  ###
    isPersistent - returns persistent state
  ###
  isPersistent: ->
    return @_persistent


  ###
    setReadOnly - lock model from changes
  ###
  setReadOnly: (readOnly) ->
    @_readOnly = true if readOnly
    @_readOnly = false unless readOnly


  ###
    isReadOnly - return read-only state
  ###
  isReadOnly: ->
    return @_readOnly

  ###
    syncChangedAttributes - return hash with attributes changed since last sync

    attr - attributes to be compared with last sync values
  ###
  syncChangedAttributes: (attr) ->
    changed = {}
    _.each attr, (value, key) =>
      unless (@belongsTo[key] or @hasMany[key] or @hasAndBelongsToMany[key] or @hasOne[key])
        if _.isArray(@syncAttributes[key]) and _.isArray(value)
          diff = _.difference(@syncAttributes[key], value)
          if diff.length
            changed[key] = attr[key]
        else if @syncAttributes[key] != attr[key]
          changed[key] = attr[key]
      else
        changed[key] = attr[key]

    changed = false if _.isEmpty(changed)
    return changed

  ###
    get - checks if request is a relation and generate apropriate return model

    This method supports deep model requests, like 'user.name' and even
    'client.person.phone_numbers[2].number'

    Parameters:
      attr - attribute name
      options - options to be used in caso of relations. Available options:
        remoteRefresh - true/false/first - if set to true will refresh relations
          from server. If set to first, only refresh on first get.
        lazyLoad - function - called when models has been loaded from server
  ###
  get: (attr, options) ->
    ## Check if any attribute is actually a relation
    ## In that case, call relation model object get method
    result = null
    if attr.indexOf('.') >= 0
      parts = attr.split('.')

      # Check for collection get
      relationAttr = parts.shift()
      indexRegex = new RegExp('([^[]*)[[](\\d{1,})]')
      collectionParts = indexRegex.exec(relationAttr)

      if collectionParts and collectionParts.length == 3
        relation = @get(collectionParts[1])
        if relation instanceof Backbone.Collection
          relation = relation.at(collectionParts[2])
        else
          return relation
      else
        relation = @get(relationAttr)

      # TODO: Should extract and pass appropriate options
      result = relation.get(parts.join('.')) if relation instanceof Backbone.RailsModel

      return result

    # Process attributeModifiers
    if @attributes[attr] and @attributeModifiers[attr] and @attributeModifiers[attr].getConverter
      if @attributeModifiers[attr].getConverter == 'DateTime'
        if @attributeModifiers[attr].options and @attributeModifiers[attr].options.format
          return @attributes[attr].toString(@attributeModifiers[attr].options.format)
        else
          return @attributes[attr].toString(@_store.getBuiltinModifierFormat('DateTime'))
      else if @attributeModifiers[attr].getConverter == 'Date'
        if @attributeModifiers[attr].options and @attributeModifiers[attr].options.format
          return @attributes[attr].toString(@attributeModifiers[attr].options.format)
        else
          return @attributes[attr].toString(@_store.getBuiltinModifierFormat('Date'))
      else if @attributeModifiers[attr].getConverter == 'Boolean'
        modifier = @_store.getBuiltinModifierFormat('Boolean')
        return modifier[1] if @attributes[attr]
        return modifier[0] if not @attributes[attr] or @attributes[attr] == 'false'
      else if _.isFunction(@attributeModifiers[attr].getConverter)
        return @attributeModifiers[attr].getConverter(@attributes[attr])

    # If we have, deliver
    val = super
    if val
      return val

    # Check if this is a belongsTo relation
    options = options || {}
    if @belongsTo[attr]
      val_id = @get("#{attr}_id")
      if val_id
        modelType = _.result(@belongsTo,attr)
        model = @_store.findById(modelType, val_id)
        options.lazyLoad(model) if model and _.isFunction(options.lazyLoad)
        return model if model
        model = new modelType({id:val_id},{silent:true})
        @_store.refresh
          models: [model]
          success: => options.lazyLoad(model) if _.isFunction(options.lazyLoad)

        return model
      return null

    # Check if this is a hasOne relation
    if @hasOne[attr]
      @_hasOneCache = {} unless @_hasOneCache
      @_hasOneCache[@cid] = {col: null, ids: []} unless @_hasOneCache[@cid]
      unless @_hasOneCache[@cid].col
        if options.remoteRefresh
          remoteRefresh = true
        else
          remoteRefresh = false
        relationModelType = _.result(@hasOne, attr)
        other_col = @_store.getCollectionFromModel(relationModelType)
        @_hasOneCache[@cid].col = new Backbone.RailsHasOneRelation
          parent: other_col
          relatedModel: @
          remoteRefresh: remoteRefresh
          lazyLoad: options.lazyLoad
          hasOneCache: @_hasOneCache
          relationModelType: relationModelType
          attribute: attr
      else if options.remoteRefresh and options.remoteRefresh != 'first'
        @_hasOneCache[@cid].col.remoteRefresh
          lazyLoad: options.lazyLoad
      else if _.isFunction(options.lazyLoad)
        options.lazyLoad(@_hasOneCache[@cid].col.child.first())
      return @_hasOneCache[@cid].col.child.first()

    # Check if this is a hasMany relation
    if @hasMany[attr]
      opts = @hasMany[attr]
      opts.subset = {} unless opts.subset
      unless opts.subset[@cid]
        if options.remoteRefresh
          remoteRefresh = true
        else
          remoteRefresh = false
        other_col = @_store.getCollectionFromModel(_.result(opts, 'modelType'))
        opts.subset[@cid] = new Backbone.RailsHasManyRelationCollection
          parent: other_col
          relatedModel: @
          remoteRefresh: remoteRefresh
          lazyLoad: options.lazyLoad
          hasMany: opts
          attribute: attr
      else if options.remoteRefresh and options.remoteRefresh != 'first'
        opts.subset[@cid].remoteRefresh
          lazyLoad: options.lazyLoad
      else if _.isFunction(options.lazyLoad)
        options.lazyLoad(opts.subset[@cid].child)
      return opts.subset[@cid].child

    # Check if this is a hasAndBelongsToMany relation
    if @hasAndBelongsToMany[attr]
      opts = @hasAndBelongsToMany[attr]
      opts.subset = {} unless opts.subset
      opts.subset[@cid] = {ids: [], collection: null, mirrors: {}} unless opts.subset[@cid]
      unless opts.subset[@cid].collection
        if options.remoteRefresh
          remoteRefresh = true
        else
          remoteRefresh = false
        other_col = @_store.getCollectionFromModel(_.result(opts, 'modelType'))
        opts.subset[@cid].collection = new Backbone.RailsManyToManyRelationCollection
          parent: other_col
          relatedModel: @
          hasAndBelongsToMany: opts
          remoteRefresh: remoteRefresh
          lazyLoad: options.lazyLoad
          attribute: attr
      else if options.remoteRefresh and options.remoteRefresh != 'first'
        opts.subset[@cid].collection.remoteRefresh
          lazyLoad: options.lazyLoad
      else if _.isFunction(options.lazyLoad)
        options.lazyLoad(opts.subset[@cid].collection.child)
      return opts.subset[@cid].collection.child

    return null


  ###
    set - controls relation updates and special storeSync event
  ###
  set: (key, value, options) ->
    if @isReadOnly()
      @trigger('change', @)
      return false

    if _.isObject( key ) || key == null
      attributes = key;
      options = value;
    else
      attributes = {};
      attributes[ key ] = value;

    options = options || {}

    belongsToIds = {}
    belongsToIdsCounter = 0;

    modelAttributes = @_cleanUpRelations(attributes)
    modelAttributes = @parse(modelAttributes) if options.parse
    modelAttributes = @_parseAttributeModifiers(modelAttributes)

    ret = super(modelAttributes,options)

    # Verify relations updating
    _.each attributes, (value, key) =>
      # Check if updating belongsTo relation
      klass = _.result(@belongsTo, key)
      if klass
        if value
          if value instanceof klass
            id = value.id || value.cid
          else
            model = @_store.findById(klass, value.id)
            unless model
              model = new klass({id: value.id},{silent:true})

            model.set(value,_.extend(options,{parse: true}))
            id = model.id || model.cid
        else
          id = null
        belongsToIds["#{key}_id"] = id
        belongsToIdsCounter++
        @trigger("change:#{key}", @)

      # Check if updating hasOne relation
      klass = _.result(@hasOne, key)
      if klass
        if value
          if value instanceof klass
            id = value.cid
          else
            if _.isArray(value)
              id = _.first(value)
              model = @_store.findById(klass, id)
              throw "Invalid model ID for hasOne relation!" unless model
              id = model.cid
            else if _.isNumber(value)
              id = value
            else
              throw "Valid not yet supported! Please consider reporting this bug with Object type"
          @_hasOneCache = {} unless @_hasOneCache
          @_hasOneCache[@cid] = {col: null, ids: []} unless @_hasOneCache[@cid]
          @_hasOneCache[@cid].ids.push(id)
          @_hasOneCache[@cid].col.refresh() if @_hasOneCache[@cid].col
          @trigger("change:#{key}", @)

      # In case trying to update hasMany relation, iterate
      if @hasMany[key]
        opts = @hasMany[key]
        klass = _.result(opts, 'modelType')
        if value instanceof Backbone.RailsCollection
          throw "Cannot update hasMany relation with a Collection!"
        else if _.isArray(value)
          # Eager data being fed from server
          _.each value, (modelAttr) =>
            if _.isObject(modelAttr)
              id = modelAttr.cid
            else
              id = modelAttr

            # Try to find model first
            model = @_store.findById(klass, id)
            if _.isObject(modelAttr)
              if model
                model.set(opts.attribute, @,_.extend(options,{parse: true}))
              else
                model = new klass({id: modelAttr.id},{silent:true})
                model.set(modelAttr,_.extend(options,{parse: true}))

            unless model
              throw "Model should have been refreshed! API BUG!"

            @trigger("change:#{key}", @)


      # In case trying to update hasAndBelongsToMany relation, iterate
      if @hasAndBelongsToMany[key]
        opts = @hasAndBelongsToMany[key]
        klass = _.result(opts, 'modelType')
        if value instanceof Backbone.RailsCollection
          throw "Cannot update hasMany relation with a Collection!"
        else if _.isArray(value)
          _.each value, (modelAttr) =>
            if _.isObject(modelAttr)
              id = modelAttr.id
            else
              id = modelAttr

            # Try to find model first
            model = @_store.findById(klass, id)
            if _.isObject(modelAttr)
              # Eager data being fed from server
              if model
                model.set(modelAttr,_.extend(options,{parse: true}))
              else
                model = new klass({id: modelAttr.id},{silent:true})
                model.set(modelAttr,_.extend(options,{parse: true}))

            unless model
              throw "Model should have been refreshed! API BUG!"

            # Save relation model id inside filter hash
            opts.subset = {} unless opts.subset
            opts.subset[@cid] = {ids: [], collection: null, mirrors: {}} unless opts.subset[@cid]
            opts.subset[@cid].ids = _.uniq(opts.subset[@cid].ids.concat(model.cid))

          opts.subset[@cid].collection.refresh() if opts.subset[@cid].collection
          @trigger("change:#{key}", @)

    if belongsToIdsCounter
      @set(belongsToIds, options)

    if options.storeSync
      @_store.reportSync(@)

    return ret

  ###
    release - release this instance from Store control
  ###
  release: ->
    @_store.release(@)

  ###
    save - request Store commit
  ###
  backboneSave: @prototype.save

  save: (options) ->
    @_store.commit(options)

  ###
    destroy - removes from server
  ###
  destroy: ->
    if @isReadOnly()
      # Ignore destroy request on read only models
      return false
    @_store.registerDestroyRequest(@)
    @collection.remove(@)
    @trigger('destroy', @)

  ###
    toJSON - send cid in case new model
  ###
  toJSON: ->
    if @_toJSONLock
      return null
    @_toJSONLock = true

    json = super
    unless @id
      json.cid = @cid

    @_toJSONLock = false
    return json

  _cleanUpRelations: (attr) ->
    attributes = _.clone(attr)
    _.each(attributes, (value, key) =>
      if @belongsTo[key] || @hasMany[key] || @hasAndBelongsToMany[key] || @hasOne[key]
        delete attributes[key]
    )
    return attributes

  _parseAttributeModifiers: (attr) ->
    _.each attr, (value, key) =>
      if @attributeModifiers[key]
        if @attributeModifiers[key].getConverter == 'DateTime'
          attr[key] = Date.parse(value) if value
        else if @attributeModifiers[key].getConverter == 'Date'
          if value instanceof Date
            attr[key] = value
          else if value
            attr[key] = Date.parseExact(value, @_store.getDateFormats())
        else if @attributeModifiers[key].getConverter == 'Boolean'
          return 1 if value
          return 0 if not value or value == 'false'
        else if _.isFunction(@attributeModifiers[key].getConverter)
          attr[key] = @attributeModifiers[key].getConverter(value)
    return attr

###
* Backbone.RailsCollection - Singleton Pattern Collection
*
* Rails Collection is a type of collection that register itself on Backbone.RailsStore
* and guarantees that all models of that type have only one instance
*
* All derived Backbone.RailsModel MUST define a derived Backbone.RailsCollection!
* After definition static setup() method MUST be called to guarantee Store proper state!
###
class Backbone.RailsCollection extends Backbone.Collection
  _store: null

  constructor: ->
    @_store = Backbone.RailsStore.getInstance()
    super

  ###
    @setup - register model type and collection to RailsStore

    This method MUST be called after Collection definition!
  ###
  @setup: ->
    store = Backbone.RailsStore.getInstance()
    store.registerType(@prototype.model)
    store.registerCollection(@)

  fetch: (options) ->
    options.storeSync = true
    success = options.success
    options.success = (resp, status, xhr) =>
      @_store.reportSyncChanges()
      success(resp, status, xhr) if success
    super

  _prepareModel: (attrs, options) ->
    if attrs instanceof Backbone.RailsModel
      unless attrs.collection
        attrs.collection = @
      return attrs

    options || (options = {})
    options.collection = @
    idSet = {}
    if attrs.id
      actual_model = @_store.findById(@model, attrs.id)
      if actual_model
        actual_model.set(attrs,options)
        return actual_model
      idSet.id = attrs.id
    model = new @model(idSet,{silent:true})
    unless model._validate(attrs, options)
      return false
    model.set(attrs, options)
    return model


###----------------------------------------------------------------------------
                          INTERNAL USE ONLY CLASSES!!!
----------------------------------------------------------------------------###

###
  Backbone.RailsStoreServer - Simple model to interface with Rails - INTERNAL USE ONLY!
###
class Backbone.RailsStoreServer extends Backbone.Model
  fetchUrlRoot:  '/backbone_rails_store/refresh'
  commitUrlRoot: '/backbone_rails_store/commit'
  findUrlRoot:   '/backbone_rails_store/find'
  authUrlRoot:   '/backbone_rails_store/auth'

  fetch: (options) ->
    options.beforeSend = (xhr) =>
      token = $('meta[name="csrf-token"]').attr('content') unless options.noCSRF
      xhr.setRequestHeader('X-CSRF-Token', token) if token
    success = options.success
    options.success = (data, resp) =>
      if resp and resp.must_reload
        window.location.replace(resp.must_reload)
        return
      success.apply(@, arguments)
    super


###
* Backbone.RailsRelationCollection - INTERNAL USE ONLY!
*
* This is the base class for hasOne, hasMany and hasAndBelongsToMany relations fetch and update
###
class Backbone.RailsRelationCollection extends Backbone.CollectionSubset
  _store: null

  constructor: (options) ->
    @_store = Backbone.RailsStore.getInstance()
    @relatedModel = options.relatedModel
    @doRemoteRefresh = options.remoteRefresh
    @lazyLoad = options.lazyLoad
    @attribute = options.attribute

    returnVal = super

    if @doRemoteRefresh
      @remoteRefresh
        lazyLoad: @lazyLoad
    else if @lazyLoad
      @lazyLoad(@child)

    return returnVal

  remoteRefresh: (options) ->
    options = options || {}

    # Request relation refresh from server
    modelType = @_store.getModelType(@relatedModel)
    fetchOptions =
      relations: {}

    fetchOptions.relations[modelType] =
      railsClass: @relatedModel.railsClass
      railsRelationClass: @relationModelType.prototype.railsClass
      railsRelationAttribute: @attribute
      relationType: @_store.getModelType(@relationModelType)
      ids: [@relatedModel.id]

    fetchOptions.success = =>
      options.lazyLoad(@child) if _.isFunction(options.lazyLoad)

    @_store.refresh(fetchOptions)


###
* Backbone.RailsHasOneRelation - INTERNAL USE ONLY
*
* This class handles hasOne relations
###
class Backbone.RailsHasOneRelation extends Backbone.RailsRelationCollection

  constructor: (options) ->
    @hasOneCache = options.hasOneCache
    @relationModelType = options.relationModelType
    options.filter = (model) =>
      return @hasOneCache[@relatedModel.cid].ids.indexOf(model.cid) != -1
    super

###
* Backbone.RailsHasManyRelationCollection - INTERNAL USE ONLY!
*
* This class handles hasMany relations
###
class Backbone.RailsHasManyRelationCollection extends Backbone.RailsRelationCollection

  constructor: (options) ->
    @relation = options.hasMany
    @relationModelType = _.result(@relation, 'modelType')
    options.filter = (model) =>
      attr_id = "#{@relation.attribute}_id"
      if @relatedModel.id?
        return model.get(attr_id) == @relatedModel.id
      else
        return model.get(attr_id) == @relatedModel.cid
    super
    @listenTo @child, 'remove', (model) => @_onChildRemove(model)

  _onChildAdd: (model, collection, options) ->
    attr = "#{@relation.attribute}_id"
    unless model.get(attr)?
      model.set(attr, @relatedModel.id || @relatedModel.cid)
    super

  _onChildRemove: (model) ->
    sourceType = @_store.getModelType(@relatedModel)
    targetType = @attribute
    sourceModelId = @relatedModel.id if @relatedModel.id
    sourceModelId = @relatedModel.cid unless @relatedModel.id
    targetModelId = model.id if model.id
    targetModelId = model.cid unless model.id
    removeOptions = {remove: {}}
    removeOptions.remove[sourceType] = {}
    removeOptions.remove[sourceType][sourceModelId] = {}
    removeOptions.remove[sourceType][sourceModelId][targetType] =
      railsClass: @_store._getModelTypeObj(@relationModelType).prototype.railsClass
      ids: [targetModelId]
    @_store.reportManyRelationEvent removeOptions

###
* Backbone.RailsManyToManyRelationCollection - INTERNAL USE ONLY!
*
* This class hangles hasAndBelongsToMany relations
###
class Backbone.RailsManyToManyRelationCollection extends Backbone.RailsRelationCollection
  _store: null

  constructor: (options) ->
    @_store = Backbone.RailsStore.getInstance()
    @relation = options.hasAndBelongsToMany
    @relationModelType = _.result(@relation, 'modelType')
    options.filter = (model) =>
      opts = @relation
      return opts.subset[@relatedModel.cid].ids.indexOf(model.cid) != -1
    super
    @parent.on 'remove', (model) => @_onChildRemove(model)
    @child.on 'remove', (model) => @_onChildRemove(model)
    @child.clear = => @clear()

  clear: ->
    modelsToRemove = []
    @child.each (model) =>
      modelsToRemove.push(model)
    _.each modelsToRemove, (model) =>
      @child.remove(model)

  _onChildAdd: (model) ->
    ids = @relation.subset[@relatedModel.cid].ids
    if ids.indexOf(model.cid) == -1
      ids.push(model.cid)
      sourceType = @_store.getModelType(@relatedModel)
      targetType = @attribute
      sourceModelId = @relatedModel.id if @relatedModel.id
      sourceModelId = @relatedModel.cid unless @relatedModel.cid
      targetModelId = model.id if model.id
      targetModelId = model.cid unless model.id
      addOptions = {add: {}}
      addOptions.add[sourceType] = {}
      addOptions.add[sourceType][sourceModelId] = {}
      addOptions.add[sourceType][sourceModelId][targetType] =
        railsClass: @_store._getModelTypeObj(@relationModelType).prototype.railsClass
        ids: [targetModelId]
      @_store.reportManyRelationEvent addOptions
    super

  _onChildRemove: (model) ->
    sourceType = @_store.getModelType(@relatedModel)
    targetType = @attribute
    sourceModelId = @relatedModel.id if @relatedModel.id
    sourceModelId = @relatedModel.cid unless @relatedModel.id
    targetModelId = model.id if model.id
    targetModelId = model.cid unless model.id
    removeOptions = {remove: {}}
    removeOptions.remove[sourceType] = {}
    removeOptions.remove[sourceType][sourceModelId] = {}
    removeOptions.remove[sourceType][sourceModelId][targetType] =
      railsClass: @_store._getModelTypeObj(@relationModelType).prototype.railsClass
      ids: [targetModelId]
    @_store.reportManyRelationEvent removeOptions
    @relation.subset[@relatedModel.cid].ids = _.without(@relation.subset[@relatedModel.cid].ids, model.cid)
    @relation.subset[@relatedModel.cid].collection.refresh()


###
  Backbone.RailsSearchResultCollection - INTERNAL USE ONLY!

  CollectionSubset derived from search that handles inclusions correctly

  TODO: Must accept comparator function and perform correct page refresh
  TODO: Register items available in store to optimize communication
###
class Backbone.RailsSearchResultCollection extends Backbone.CollectionSubset
  _store: null

  constructor: (options) ->
    @_store = Backbone.RailsStore.getInstance()
    @cid = options.cid
    @modelType = options.modelType
    @filterData = options.filterData
    @pageData = options.pageData
    @changingPage = false
    @newModelsCids = []

    delete options.cid
    delete options.modelType
    delete options.filterData
    delete options.pageData

    options.refresh = false
    options.triggers = 'cid'
    options.filter = (model) =>
      _.indexOf(@filterData, model.cid) != -1

    super

    @child.comparator = (model) =>
      return @filterData.indexOf(model.cid)

    @child.release = => @release()
    @child.actualPageFirstItem = => @actualPageFirstItem()
    @child.actualPageLastItem = => @actualPageLastItem()
    @child.lastItem = => @lastItem()
    @child.maxLength = => @maxLength()
    @child.totalPages = => @totalPages()
    @child.actualPage = => @actualPage()
    @child.nextPage = => @nextPage()
    @child.previousPage = => @previousPage()
    @child.firstPage = => @firstPage()
    @child.lastPage = => @lastPage()
    @child.pageSize = => @pageSize()
    refreshTimeout = null
    @listenTo @child, 'remove', (model) =>
      @filterData = _.without(@filterData, model.cid)
      if @pageData.ids
        if model.id
          @pageData.ids = _.without(@pageData.ids, model.id)
        else
          @pageData.ids = _.without(@pageData.ids, model.cid)
      unless refreshTimeout
        refreshTimeout = setTimeout =>
          @_refreshCurrentPage()
          refreshTimeout = null
        , 100

  release: ->
    @_store.releaseSearchCollection(@)

  actualPageFirstItem: ->
    return ((@pageData.actualPage-1) * @pageData.pageSize) if @pageData.pageSize
    return 0

  actualPageLastItem: ->
    return 0 unless @pageData.pageSize > 0
    item = ((@pageData.actualPage-1) * @pageData.pageSize) + @pageData.pageSize - 1
    return @lastItem() if @lastItem() < item
    return item

  lastItem: ->
    return @pageData.ids.length-1

  maxLength: ->
    return @pageData.ids.length

  totalPages: ->
    if @pageData.pageSize > 0
      pages = @pageData.ids.length / parseFloat(@pageData.pageSize)
      pagesInteger = parseInt(pages)
      pagesDecimal = (pages * 10) - pagesInteger*10
      return pagesInteger if pagesDecimal < 1
      return pagesInteger+1
    return 1

  actualPage: ->
    return @pageData.actualPage

  nextPage: ->
    return false if @changingPage
    @changingPage = true
    actualPage = @actualPage()
    lastIdx = @maxLength()
    pageSize = @pageData.pageSize
    beginIdx = actualPage*pageSize
    endIdx = beginIdx+pageSize
    if beginIdx >= lastIdx
      @changingPage = false
      return false
    refreshIds = @pageData.ids.slice(beginIdx, endIdx)
    @_refreshPage(refreshIds, 1)

  previousPage: ->
    return false if @changingPage
    @changingPage = true
    actualPage = @actualPage()-2
    firstIdx = 0
    pageSize = @pageData.pageSize
    beginIdx = actualPage*pageSize
    endIdx = beginIdx+pageSize
    if beginIdx < firstIdx
      @changingPage = false
      return false
    refreshIds = @pageData.ids.slice(beginIdx, endIdx)
    @_refreshPage(refreshIds, -1)

  pageSize: ->
    return @pageData.pageSize

  _refreshCurrentPage: ->
    return false if @changingPage
    @changingPage = true
    actualPage = @actualPage()-1
    lastIdx = @maxLength()
    pageSize = @pageData.pageSize
    pageSize = lastIdx unless pageSize > 0
    beginIdx = actualPage*pageSize
    endIdx = beginIdx+pageSize
    if beginIdx >= lastIdx
      @changingPage = false
      return false
    refreshIds = @pageData.ids.slice(beginIdx, endIdx)
    @_refreshPage(refreshIds, 0)

  _refreshPage: (refreshIds, increment) ->
    modelsIds = {}
    validIds = _.difference(refreshIds, @newModelsCids)
    pageCids = _.intersection(refreshIds, @newModelsCids)
    modelsIds[@modelType] =
      railsClass: @_store.getModelType(@modelType)
      ids: validIds
    @_store.refresh
      success: =>
        @filterData.length = 0
        _.each refreshIds, (id) =>
          model = @_store.findById(@modelType, id)
          @filterData.push(model.cid)
        @pageData.actualPage += increment
        @refresh()
        @changingPage = false
      modelsIds: modelsIds

  _onChildAdd: (model, collection, options) ->
    @filterData.push(model.cid)
    if model.id
      @pageData.ids.push(model.id) if model.id
    else
      @pageData.ids.push(model.cid)
      @newModelsCids.push(model.cid)
    @_refreshCurrentPage()
    super

