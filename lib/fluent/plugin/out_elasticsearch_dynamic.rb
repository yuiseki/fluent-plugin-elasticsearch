# encoding: UTF-8
require '/fluent/plugin/out_elasticsearch'

class Fluent::ElasticsearchOutputDynamic < Fluent::ElasticsearchOutput

  Fluent::Plugin.register_output('elasticsearch_dynamic', self)

  config_param :delimiter, :string, :default => "."

  def configure(conf)
    super

    # evaluate all configurations here
    @dynamic_config = Hash.new
    self.instance_variables.each { |var|
      if is_valid_expand_param_type(var)
        value = expand_param(self.instance_variable_get(var), nil, nil)

        var = var.to_s.gsub(/@(.+)/){ $1 }
        @dynamic_config[var] = value
      end
    }
    # end eval all configs
  end

  def client
    @_es ||= begin
      excon_options = { client_key: @dynamic_config['client_key'], client_cert: @dynamic_config['client_cert'], client_key_pass: @dynamic_@dynamic_config['client_key_pass'] }
      adapter_conf = lambda {|f| f.adapter :excon, excon_options }
      transport = Elasticsearch::Transport::Transport::HTTP::Faraday.new(get_connection_options.merge(
                                                                          options: {
                                                                            reload_connections: @dynamic_config['reload_connections'],
                                                                            reload_on_failure: @dynamic_config['reload_on_failure'],
                                                                            retry_on_failure: 5,
                                                                            transport_options: {
                                                                              request: { timeout: @dynamic_config['request_timeout'] },
                                                                              ssl: { verify: @dynamic_config['ssl_verify'], ca_file: @dynamic_config['ca_file'] }
                                                                            }
                                                                          }), &adapter_conf)
      es = Elasticsearch::Client.new transport: transport

      begin
        raise ConnectionFailure, "Can not reach Elasticsearch cluster (#{connection_options_description})!" unless es.ping
      rescue *es.transport.host_unreachable_exceptions => e
        raise ConnectionFailure, "Can not reach Elasticsearch cluster (#{connection_options_description})! #{e.message}"
      end

      log.info "Connection opened to Elasticsearch cluster => #{connection_options_description}"
      es
    end
  end

  def get_connection_options
    raise "`password` must be present if `user` is present" if @dynamic_config['user'] && !@dynamic_config['password']

    hosts = if @hosts
      @hosts.split(',').map do |host_str|
        # Support legacy hosts format host:port,host:port,host:port...
        if host_str.match(%r{^[^:]+(\:\d+)?$})
          {
            host:   host_str.split(':')[0],
            port:   (host_str.split(':')[1] || @dynamic_config['port']).to_i,
            scheme: @dynamic_config['scheme']
          }
        else
          # New hosts format expects URLs such as http://logs.foo.com,https://john:pass@logs2.foo.com/elastic
          uri = URI(host_str)
          %w(user password path).inject(host: uri.host, port: uri.port, scheme: uri.scheme) do |hash, key|
            hash[key.to_sym] = uri.public_send(key) unless uri.public_send(key).nil? || uri.public_send(key) == ''
            hash
          end
        end
      end.compact
    else
      [{host: @dynamic_config['host'], port: @dynamic_config['port'], scheme: @dynamic_config['scheme']}]
    end.each do |host|
      host.merge!(user: @dynamic_config['user'], password: @dynamic_config['password']) if !host[:user] && @dynamic_config['user']
      host.merge!(path: @dynamic_config['path']) if !host[:path] && @dynamic_config['path']
    end

    {
      hosts: hosts
    }
  end

  def write(chunk)
    bulk_message = []

    chunk.msgpack_each do |tag, time, record|
      next unless record.is_a? Hash

      # evaluate all configurations here
      self.instance_variables.each { |var|
        if is_valid_expand_param_type(var)
          value = expand_param(self.instance_variable_get(var), tag, record)

          var = var.to_s.gsub(/@(.+)/){ $1 }
          @dynamic_config[var] = value
        end
      }
      # end eval all configs

      if @logstash_format
        if record.has_key?("@timestamp")
          time = Time.parse record["@timestamp"]
        elsif record.has_key?(@time_key)
          time = Time.parse record[@dynamic_config['time_key']]
          record['@timestamp'] = record[@dynamic_config['time_key']]
        else
          record.merge!({"@timestamp" => Time.at(time).to_datetime.to_s})
        end

        if @dynamic_config['utc_index']
          target_index = "#{@dynamic_config['logstash_prefix']}-#{Time.at(time).getutc.strftime("#{@dynamic_config['logstash_dateformat']}")}"
        else
          target_index = "#{@dynamic_config['logstash_prefix']}-#{Time.at(time).strftime("#{@dynamic_config['logstash_dateformat']}")}"
        end
      else
        target_index = @dynamic_config['index_name']
      end

      if @dynamic_config['include_tag_key']
        record.merge!(@dynamic_config['tag_key'] => tag)
      end

      meta = { "index" => {"_index" => target_index, "_type" => @dynamic_config['type_name']} }
      if @dynamic_config['id_key'] && record[@dynamic_config['id_key']]
        meta['index']['_id'] = record[@dynamic_config['id_key']]
      end

      if @dynamic_config['parent_key'] && record[@dynamic_config['parent_key']]
        meta['index']['_parent'] = record[@dynamic_config['parent_key']]
      end

      bulk_message << meta
      bulk_message << record
    end

    send(bulk_message) unless bulk_message.empty?
    bulk_message.clear
  end

  def expand_param(param, tag, record)
    # check for '${ ... }'
    #   yes => `eval`
    #   no  => return param
    return param if (param =~ /^\${.+}$/).nil?

    # check for 'tag_parts[]'
      # separated by a delimiter (default '.')
    tag_parts = tag.split(@delimiter) unless (param =~ /tag_parts\[.+\]/).nil?

    # pull out section between ${} then eval
    param.gsub(/^\${(.+)}$/) {
      eval( $1 )
    }
  end

  def is_valid_expand_param_type(param)
    return (self.instance_variable_get(param).is_a?(String) || self.instance_variable_get(param).is_a?(TrueClass) || self.instance_variable_get(param).is_a?(FalseClass) || self.instance_variable_get(param).is_a?(Numeric) )
  end
end
