require 'uri'

class ServiceDiscovery
  attr_accessor :node
  attr_writer :search_engine, :ip_finder

  def initialize(node)
    @node = node
  end

  def announce_service(service, params)
    service_data = normalize_service_params(params)

    if node['announced_services'][service.to_s] != service_data
      node.set['announced_services'][service.to_s] = service_data
      node.save unless Chef::Config.solo
    end
  end

  def discover_nodes_for(service, params = {})
    params = {
      :environment => node.chef_environment,
      :environment_aware => true,
      :cluster => node['cluster'],
      :cluster_aware => true,
      :data_center => node['data_center'],
      :data_center_aware => false
    }.merge(symbolize_keys(params))

    query = ["announced_services:#{service.to_s}"]
    query << "chef_environment:#{params[:environment]}" if params[:environment_aware]
    query << "announced_services_#{service.to_s}_cluster:#{params[:cluster]}" if params[:cluster_aware]
    query << "data_center:#{params[:data_center]}" if params[:data_center_aware]

    results = Array.new
    search_engine.search(:node, query.join(" AND ")) do |n|
      unless params[:exclude_self] && node == n
        yield n if block_given?
        results << n
      end
    end

    results
  end

  def discover_connection_endpoints_for(service, params = {})
    params = symbolize_keys(params)
    required = params.delete(:require) || {}
    preferred = params.delete(:prefer) || {}
    target_node = params.delete(:node)
    target_nodes = params.delete(:nodes)

    nodes = if target_node
              [target_node]
            else
              target_nodes || discover_nodes_for(service, params)
            end

    results = Array.new
    nodes.each do |n|
      results << find_best_connection_endpoint_for_node(n, service, required, preferred)
    end

    results.compact
  end

  private

  def find_best_connection_endpoint_for_node(n, service, required = {}, preferred = {})
    return unless n['announced_services'] && n['announced_services'][service.to_s]

    endpoints = [n['announced_services'][service.to_s]['listening_on']].flatten.compact.map { |l| symbolize_keys(l) }
    return if endpoints.empty?

    results = match_elements(endpoints, required, preferred)
    unless required[:scope]
      guessed_scope = guess_scope(n)
      results.select! { |l| l[:scope] == guessed_scope }
    end

    results.first
  end

  def match_elements(elements, required, preferred = {})
    results = elements.select { |elem| includes_hash?(elem, required) }
    unless preferred.empty?
      rs = results.select { |elem| includes_hash?(elem, preferred) }
      results = rs unless rs.empty?
    end

    results
  end

  def includes_hash?(h1, h2)
    h2.map { |key, _| h1[key] == h2[key] }.all?
  end

  def guess_scope(remote_node)
    return 'node' if node == remote_node

    return 'private' if node['data_center'] != nil && node['data_center'] == remote_node['data_center']

    if cloud_provider_for_node(node) != nil && cloud_provider_for_node(node) == cloud_provider_for_node(remote_node)
      if cloud_provider_for_node(remote_node) == "ec2"
        if region_for_ec2_node(node) == region_for_ec2_node(remote_node)
          return 'private'
        else
          return 'public'
        end
      end

      # FIXME: this is not true for all cloud providers!
      return 'private'
    end

    'public'
  end

  def cloud_provider_for_node(node)
    if node.has_key?('cloud') && node['cloud'].has_key?('provider')
      node['cloud']['provider']
    else
      nil
    end
  end

  def region_for_ec2_node(node)
    if node.has_key?('ec2') &&
        node['ec2'].has_key?('placement_availability_zone')
      node['ec2']['placement_availability_zone'].gsub(/(\d+).+/, '\1')
    else
      nil
    end
  end

  def normalize_service_params(params)
    params = symbolize_keys(params)

    params[:listening_on] = [params[:listening_on]].compact.flatten.inject([]) do |norm, l|
      norm += normalize_listening_entry(l)
    end

    params[:cluster] ||= node['cluster']

    params
  end

  def normalize_listening_entry(l)
    results = Array.new

    if l[:url]
      url = URI.parse(l.delete(:url))
      l[:protocol] = url.scheme
      l[:address] = url.host
      l[:port] = url.port
    end

    l[:address] ||= "0.0.0.0"
    l[:socket_type] ||= 'tcp'

    if l[:address] == "0.0.0.0"
      ip_finder.find_all(node).each do |scope, ip|
        results << l.merge(:scope => scope, :address => ip.first)
      end
    else
      if is_filepath?(l[:address])
        l[:socket_type] = "unix"
        l[:scope] = "node"
      elsif is_ipscope?(l[:address])
        l[:address] = ip_finder.find_one(node, l[:address])
      end

      l[:scope] ||= ip_finder.ip_to_scope(l[:address]).first if is_ipaddr?(l[:address])

      results << l
    end

    results
  end

  def is_ipaddr?(s)
    !!(IPAddr.new(s) rescue nil)
  end

  def is_filepath?(s)
    s.split('/').size > 1
  end

  def is_ipscope?(s)
    (!is_filepath?(s) && s.split('_').size > 1) || %w(local private pubic).include?(s)
  end

  def symbolize_keys(hash)
    hash.inject({}) do |result, (key, value)|
      new_key = case key
                when String then key.to_sym
                else key
                end
      new_value = case value
                  when Hash then symbolize_keys(value)
                  when Array
                    value.map do |item|
                      case item
                      when Hash then symbolize_keys(item)
                      else item
                      end
                    end
                  else value
                  end
      result[new_key] = new_value
      result
    end
  end

  def search_engine
    @search_engine ||= Chef::Search::Query.new
  end

  def ip_finder
    @ip_finder ||= Chef::IPFinder
  end

  module DSL
    def announce_service(service, params)
      disco = ServiceDiscovery.new(node)
      disco.announce_service(service, params)
    end

    def discover_nodes_for(service, params = {}, &block)
      disco = ServiceDiscovery.new(node)
      disco.discover_nodes_for(service, params, &block)
    end

    def discover_connection_endpoints_for(service, params = {})
      disco = ServiceDiscovery.new(node)
      disco.discover_connection_endpoints_for(service, params)
    end
  end
end

Chef::Recipe.send(:include, ServiceDiscovery::DSL)
Chef::Resource.send(:include, ServiceDiscovery::DSL)
Chef::Provider.send(:include, ServiceDiscovery::DSL)

