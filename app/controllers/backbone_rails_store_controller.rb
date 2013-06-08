###
#  Copyright (C) 2013 - Raphael Derosso Pereira <raphaelpereira@gmail.com>
#
#  Backbone.RailsStore - version 1.0.3
#
#  Backbone extensions to provide complete Rails interaction on CoffeeScript/Javascript,
#  keeping single reference models in memory, reporting refresh conflicts and consistently
#  persisting models and there relations.
#
#  Backbone.RailsStore may be freely distributed under the MIT license.
#
###

class ErrorTransportException < RuntimeError
  attr :errors

  def initialize(errors)
    @errors = errors
  end

end

class BackboneRailsStoreController < ApplicationController
  skip_before_filter :authenticated, :only => 'authenticate'

  def authenticate
    response = {}
    begin
      ActiveRecord::Base.transaction do
        if params[:authModel]
          klass = params[:authModel][:railsClass]
          model = klass.constantize.where(:login => params[:authModel][:model][:login]).first
          if model
            token = params[:authModel][:model][:token]
            hash = Digest::SHA1.hexdigest("#{token}#{model.password}")
            if hash == params[:authModel][:model][:hash]
              response = {}
              response[:authModel] = {
                  :railsClass => klass,
                  :id => model.id
              }
              response.merge! (refreshModels({
                  :"#{klass}" => {
                      :railsClass => klass,
                      :ids => [model.id]
                  }
                                       }))
              session[:current_user] = model.id if model
            end
          end
        end
      end
    rescue => exp
      response = {errors: exp.errors}
    end

    respond_to do |format|
      format.json { render json: response }
    end
  end

  def logout
    response = {}
    ActiveRecord::Base.transaction do
      session[:current_user] = nil
    end
    respond_to do |format|
      format.json { render json: response }
    end
  end

  # TODO: This method should be separated in other methods (refresh, commit, destroy, search)
  def refresh
    response = {}
    begin
      ActiveRecord::Base.transaction do

        # Prepare response for requested models
        response = {}

        # Relations to be fetched
        relations = params[:relations]

        if relations
          response[:models] = {}
          resp_relations = response[:relations] = {}

          # TODO: Optimize!
          relations.each do |model_type, model_info|
            model_class = model_info[:railsClass].constantize
            relation_type = model_info[:relationType]
            relation_class = model_info[:railsRelationClass]
            relation_attribute = model_info[:railsRelationAttribute].underscore.to_sym
            resp_relations[model_type] = {} unless resp_relations[model_type]
            resp_relations[model_type][relation_type] = {
              :attribute => model_info[:railsRelationAttribute],
              :models => {}
            } unless resp_relations[model_type][relation_type]

            model_class.where(:id => model_info[:ids]).each do |model|
              relation_objs = model.send(relation_attribute)
              resp_relations[model_type][relation_type][:models][model.id] = relation_objs.map do |rm|
                rm.id
              end
              response[:models][relation_class.to_s] = [] unless response[:models][relation_class.to_s]
              response[:models][relation_class.to_s].concat(relation_objs)
              fill_eager_refresh relation_class, relation_objs, response
            end
          end
        end
      end

    rescue ErrorTransportException => exp
      response = {errors: exp.errors}
    end

    respond_to do |format|
      format.json { render json: response }
    end
  end

  def find
    response = {}
    begin
      ActiveRecord::Base.transaction do

        # Models to be searched
        models = params[:searchModels]
        if models
          params[:refreshModels] = {} unless params[:refreshModels]
          response[:models] = {} if not response[:models]
          models = [models] if not models.kind_of?(Array)
          page_data = response[:pageData] = {}
          models.each do |model_info|
            rails_class = model_info[:railsClass].constantize
            result = rails_class.rails_store_search(model_info[:searchParams])
            page = model_info[:page].to_i
            page = 1 if page == 0
            limit = model_info[:limit].to_i
            limit_low = 0
            limit_high = result.count
            if limit > 0
              limit_low = (page-1) * limit
              limit_high = limit_low+limit-1
            end
            counter = 0
            pages = 1
            pages = (result.count.to_f / limit.to_f).ceil.to_i if limit > 0
            page_data[model_info[:railsClass]] = {
              :ids => [],
              :pageSize => limit,
              :actualPage => page,
              :pages => pages
            }
            response[:models][model_info[:railsClass]] = []
            result.each do |m|
              page_data[model_info[:railsClass]][:ids].push(m.id)
              if limit == 0 or (limit_low <= counter and counter <= limit_high)
                response[:models][model_info[:railsClass]].push(m)
              end
            end
            fill_eager_refresh rails_class, response[:models][model_info[:railsClass]], response
          end
        end

      end

    rescue ErrorTransportException => exp
      response = {errors: exp.errors}
    end

    respond_to do |format|
      format.json { render json: response }
    end
  end

  def commit
    response = {}
    begin
      ActiveRecord::Base.transaction do

        # First persist models
        models = params[:commitModels]
        if models
          new_models = {}
          set_after_create = []
          models_ids = response[:modelsIds] = {}
          models.each do |key, model_info|
            klass = model_info[:railsClass]
            model_info[:data].each do |model|
              if model['id']
                server_model = klass.constantize.find(model['id'])
              else
                server_model = klass.constantize.create(model)
                raise_error(server_model) if not server_model.errors.empty?
                new_models[model['cid']] = server_model
                models_ids[key.to_sym] = {} unless models_ids[key.to_sym]
                models_ids[key.to_sym][:"#{model['cid']}"] = server_model.id
                params[:refreshModels] = {} if not params[:refreshModels]
                params[:refreshModels][key] = {
                    :railsClass => klass,
                    :ids => []
                } if not params[:refreshModels][key]
                params[:refreshModels][key][:ids].push(server_model.id)
              end

              updated = server_model.update_attributes(model)
              raise_error(server_model) if not updated

              model.each do |attr_key, attr|
                if attr_key.match(/.*_id$/)
                  if attr.to_s().match(/c[[:digit:]]*/)
                    set_after_create.push({
                                              :model => server_model,
                                              :railsClass => klass,
                                              :key => key,
                                              :attr  => attr_key,
                                              :temp_id => attr
                                          })
                  else
                    server_model[attr_key] = attr
                  end
                end
              end
              saved = server_model.save
              raise_error(server_model) if not saved
            end
          end

          set_after_create.each do |info|
            info[:model][info[:attr]] = new_models[info[:temp_id]].id
            saved = info[:model].save
            params[:refreshModels][info[:key]] = {
                :railsClass => info[:railsClass],
                :ids => []
            } if not params[:refreshModels][info[:key]]
            params[:refreshModels][info[:key]][:ids].push(info[:model].id)
            raise_error(info[:model]) unless saved
          end
        end

        # Destroy models
        models = params[:destroyModels]
        if models
          models.each do |key, model_info|
            model_info.each do |model|
              if model['id']
                key.constantize.destroy(model['id'])
              end
            end
          end
        end

        # Create Relations
        relations = params[:createRelations]
        if relations
          relations.each do |key, data|
            klass = data[:railsClass]
            data[:models].each do |id, data|
              data.each do |relation, data|
                relation_klass = data[:railsClass]
                new_relations = relation_klass.constantize.where(:id => data[:ids])
                model = klass.constantize.find(id)
                actual_relations = model.send("#{relation}")
                new_relations.each do |relation|
                  actual_relations.push relation unless actual_relations.include?(relation)
                end
              end
            end
          end
        end

        # Destroy Relations
        relations = params[:destroyRelations]
        if relations
          relations.each do |key, data|
            klass = data[:railsClass]
            data[:models].each do |id, data|
              data.each do |relation, data|
                next if data.nil?
                data[:ids] = [] if data[:ids].nil? or not data[:ids].is_a?(Array)
                relation_array = klass.constantize.find(id).send("#{relation}")
                result_relations = relation_array.reject do |relation_model|
                  data[:ids].include?(relation_model.id)
                end
                klass.constantize.find(id).send("#{relation}=", result_relations)
              end
            end
          end
        end

        response.merge!(refreshModels(params[:refreshModels])) if params[:refreshModels]
      end

    rescue ErrorTransportException => exp
      response = {errors: exp.errors}
    end

    respond_to do |format|
      format.json { render json: response }
    end
  end

  def upload
    response = {success: true}
    begin
      ActiveRecord::Base.transaction do
        klass = params[:railsClass].constantize
        field = params[:railsAttr]
        f = klass.create()
        data = {field.to_sym => request.request_parameters[:qqfile]}
        f.update_attributes(data)
        response[:id] = f.id
      end
    rescue ErrorTransportException => exp
      response = {errors: exp.errors}
    end

    respond_to do |format|
      format.json { render json: response }
    end
  end




  private

  def raise_error(model)
    errors = {
        :railsClass => model.class.name,
        :model => model,
        :errors => model.errors
    }
    raise ErrorTransportException.new(errors), "Doh!"
  end

  def refreshModels models
    response = {
        :models => {},
        :relations => {}
    }
    resp_models = response[:models]
    resp_relations = response[:relations]

    # Retrieve all models and then eager load
    models.each do |key, model_info|
      # TODO: in case model has been erased on server, notify
      ids = model_info[:ids] || []
      model_class = model_info[:railsClass].constantize
      server_models = model_class.where(:id => ids.uniq)
      models_eager = {:models => {}, :relations => {}}
      fill_eager_refresh model_class, server_models, models_eager
      resp_models[model_info[:railsClass]] = server_models
      resp_models.merge!(models_eager[:models]) do |key, v1, v2|
        v1.concat(v2)
      end
      resp_relations.merge!(models_eager[:relations]) do |key, v1, v2|
        v1.merge!(v2) do |key, v1, v2|
          v1[:models].merge!(v2[:models]) do |key, v1, v2|
            v1.concat(v2)
            v1
          end
        end
      end
    end

    return response
  end

  def fill_eager_refresh klass, models, models_eager
    return unless klass.respond_to?(:rails_store_eager)
    klass.rails_store_eager.each do |relation|
      relation_reflection = klass.reflect_on_association(relation)
      raise "Invalid relation #{relation} on #{klass}!" unless relation_reflection
      relation_class = relation_reflection.class_name.to_s
      models_eager[:models][relation_class] = [] unless models_eager[:models][relation_class]
      relation_objs = models.map do |obj|
        obj.send(relation)
      end.flatten
      relation_ids = relation_objs.map do |obj|
        models_eager[:models][relation_class].push(obj)
        obj.id
      end
      models_eager[:models][relation_class].uniq!
      case relation_reflection.macro
        when :has_and_belongs_to_many, :has_one
          models_eager[:relations][klass.to_s] = {} unless models_eager[:relations][klass.to_s]
          models_eager[:relations][klass.to_s][relation_class] = {
              :attribute => relation,
              :models => {}
          } unless models_eager[:relations][klass.to_s][relation_class]
          rmodels = models_eager[:relations][klass.to_s][relation_class][:models]
          relation_ids.each do |mid|
            rmodels[mid.id] = [] unless rmodels[mid.id]
            rmodels[mid.id].push(mid.relation_id)
          end
      end
      fill_eager_refresh(relation_reflection.klass, models_eager[:models][relation_class], models_eager)
    end
  end

  def sanetize_search_params(params)
    params = params.symbolize_keys
    if params[:joins]
      params[:joins] = [params[:joins]] if not params[:joins].kind_of?(Array)
      params[:joins] = params[:joins].inject([]) do |result, value|
        value = case value
                when String then value.to_sym
                else value
                end
        result.push(value)
      end
    end
    return params
  end
end
