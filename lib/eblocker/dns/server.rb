#
# Copyright 2020 eBlocker Open Source UG (haftungsbeschraenkt)
#
# Licensed under the EUPL, Version 1.2 or - as soon they will be
# approved by the European Commission - subsequent versions of the EUPL
# (the "License"); You may not use this work except in compliance with
# the License. You may obtain a copy of the License at:
#
#   https://joinup.ec.europa.eu/page/eupl-text-11-12
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" basis,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied. See the License for the specific language governing
# permissions and limitations under the License.
#
require 'async/dns'
require 'async/dns/system'
require 'eblocker/dns/cache'
require 'json'
require 'redis'
require 'set'
require 'ipaddr'

module Eblocker::Dns

  class Server < Async::DNS::Server

    CACHE_SIZE = 512
    MINIMUM_TTL = 10
    LOCAL_TTL = 60
    BLOCK_TTL = 10

    PUBLISH_STATS_DELAY = 20
    RESPONSE_STATS_MAX_LENGTH = 25000

    class Config
      attr_reader :default_resolver
      attr_reader :clients
      attr_reader :resolvers
      attr_reader :local_records
      attr_reader :local_vpn_records
      attr_reader :filtered_peers
      attr_reader :name_server_name
      attr_reader :vpn_net

      def initialize(default_resolver, clients, resolvers, local_records, local_vpn_records, name_server_name, filtered_peers, vpn_net)
        @default_resolver = default_resolver
        @clients = clients
        @resolvers = resolvers
        @local_records = local_records
        @local_vpn_records = local_vpn_records
        @name_server_name = name_server_name
        @filtered_peers = filtered_peers
        @vpn_net = vpn_net
      end
    end

    def initialize(listeners, redis_pool)
      super(listeners)
      @cache = Cache.new(CACHE_SIZE)
      @redis_pool = redis_pool
      @stats = []

      load_config

      Async::Task.current.async do |task|
        while true
          task.sleep PUBLISH_STATS_DELAY
          publish_stats if @config
        end
      end
    end

    def process(name, resource_class, transaction)
      if (!@config)
        @logger.warn("no configuration set - can not answer query")
        return transaction.fail!(:ServFail)
      end

      peer = get_peer(transaction)
      stats_key_prefix = "dns_stats:#{Time.now.strftime('%Y%m%d%H%M')}:#{peer.gsub(':', "_")}"

      @stats << "#{stats_key_prefix}:queries"
      @stats << "stats_total:dns:queries"

      local_record = get_local_record(peer, name, resource_class)
      if local_record
        @logger.debug("resolving local entry #{name} #{resource_class}: #{local_record}")
        return respond(transaction, resource_class, local_record, LOCAL_TTL)
      end

      if @config.filtered_peers.include?(peer)
        response = process_filtered_peer(name, resource_class, transaction, peer, stats_key_prefix)
        return response if response
      end

      resolver_name = @config.clients[peer] || :default
      resolver = @config.resolvers[resolver_name] || @config.default_resolver
      transaction.passthrough!(resolver)
    end

    def get_peer(transaction)
      peer = transaction.options[:remote_address]
      return peer.ip_address if peer.ipv4?
      return peer.ipv6_to_ipv4.ip_address if peer.ipv6_v4mapped?
      peer.ip_address.sub(/%.*/, '')
    end

    def get_local_record(peer, name, resource_class)
      if @config.vpn_net && @config.vpn_net.include?(peer)
        @logger.debug("resolving from VPN peer #{peer}")
        return @config.local_vpn_records[name][resource_class] if @config.local_vpn_records[name]
      end

      @logger.debug("resolving from local network peer #{peer}")
      local_records = @config.local_records[resource_class]
      return local_records ? local_records[name] : nil
    end

    def load_config
      Async::Task.current.async do |task|
        json_config = nil
        while !json_config
          begin
            json_config = @redis_pool.connection do |redis|
              redis.get('DnsServerConfig')
            end
          rescue IOError, Redis::BaseConnectionError => e
            @logger.warn "failed to load configuration: #{e.message}"
          end
          task.sleep(10) unless json_config
        end
        config = JSON::parse(json_config, :symbolize_names => true) if json_config
        set_config(config)
      end
    end

    def set_config(config)
      @logger.info("setting configuration: #{config}")

      if (!config)
        @logger.warn("no configuration found - will not serve any requests")
        @config = nil
        return
      end

      # symbolize config names for client map
      clients = config[:resolverConfigNameByIp] || {}
      clients = clients.inject({}){|m,(k,v)| m[k.to_s] = v.to_sym; m}

      # create resolver configs
      resolver_configs = config[:resolverConfigs] || {}
      resolvers = {}
      resolver_configs.each do |k, v|
        resolvers[k] = create_resolver(v, @cache)
      end

      # set default resolver
      default_resolver_sym = config[:defaultResolver].to_sym
      default_resolver = resolvers[default_resolver_sym]

      # take first builtin name as name server name
      name_server_name = find_name_server_name(config[:localDnsRecords] || [])

      # create local dns entries including inverse entries
      records = create_local_records(config[:localDnsRecords] || [])
      local_records = records[0]
      local_vpn_records = records[1]

      # filtered peers
      filtered_peers = Hash[config[:filteredPeers].collect { |p| [p, true]}]
      filtered_peers.merge!(Hash[config[:filteredPeersDefaultAllow].collect { |p| [p, false] }]) if config[:filteredPeersDefaultAllow]

      # VPN server settings (eBlocker mobile)
      if config[:vpnSubnetIp] && config[:vpnSubnetNetmask]
        vpn_net = IPAddr.new(config[:vpnSubnetIp]).mask(config[:vpnSubnetNetmask])
      else
        vpn_net = nil
      end

      # save old config to write stats after new config has been activated
      old_config = @config

      # activate new config
      @config = Config.new(default_resolver, clients, resolvers, local_records, local_vpn_records, name_server_name, filtered_peers, vpn_net)
      @logger.debug('config ' + config.inspect)

      # finally write counters from old_config
      publish_stats(old_config) if old_config
    end

    def find_name_server_name(config_local_records)
      record = config_local_records.find { |r| r[:builtin] }
      record[:name].to_s if record
    end

    def create_local_records(config_local_records)
      local_records = Hash.new
      local_records[Resolv::DNS::Resource::IN::A] = Hash.new
      local_records[Resolv::DNS::Resource::IN::AAAA] = Hash.new
      local_records[Resolv::DNS::Resource::IN::PTR] = Hash.new

      local_vpn_records = Hash.new
      local_vpn_records[Resolv::DNS::Resource::IN::A] = Hash.new
      local_vpn_records[Resolv::DNS::Resource::IN::AAAA] = Hash.new
      local_vpn_records[Resolv::DNS::Resource::IN::PTR] = Hash.new

      config_local_records.each do |r|
        k = r[:name].to_s
        dns_name = Resolv::DNS::Name.create(k)

        local_records[Resolv::DNS::Resource::IN::A][k] = r[:ipAddress] if r[:ipAddress]
        local_records[Resolv::DNS::Resource::IN::PTR][reverse(r[:ipAddress])] = dns_name if r[:ipAddress]
        local_records[Resolv::DNS::Resource::IN::AAAA][k] = r[:ip6Address] if r[:ip6Address]
        local_records[Resolv::DNS::Resource::IN::PTR][reverse(r[:ip6Address])] = dns_name if r[:ip6Address]
        local_records[Resolv::DNS::Resource::IN::PTR][reverse_rfc1886(r[:ip6Address])] = dns_name if r[:ip6Address]

        local_vpn_records[Resolv::DNS::Resource::IN::A][k] = r[:vpnAddress] if r[:vpnAddress]
        local_vpn_records[Resolv::DNS::Resource::IN::PTR][reverse(r[:vpnAddress])] = dns_name if r[:vpnAddress]
        local_vpn_records[Resolv::DNS::Resource::IN::AAAA][k] = r[:vpn6Address] if r[:vpn6Address]
        local_vpn_records[Resolv::DNS::Resource::IN::PTR][reverse(r[:vpn6Address])] = dns_name if r[:vpn6Address]
        local_vpn_records[Resolv::DNS::Resource::IN::PTR][reverse_rfc1886(r[:vpn6Address])] = dns_name if r[:vpn6Address]
      end

      [local_records, local_vpn_records]
    end

    def reverse(ip)
      IPAddr.new(ip).reverse
    end

    def reverse_rfc1886(ip)
      IPAddr.new(ip).ip6_int
    end

    def flush_cache
      @logger.info("flushing cache containing #{@cache.size} entries")
      @cache.clear
    end

    def dump_cache
      @logger.debug(@cache.to_s)
    end

    def dump_stats
      @config.resolvers.each do |k, v|
        @logger.debug("#{k}: #{v.counter.inspect}")
      end
    end

    def publish_stats(config = @config)
      @logger.debug('publishing stats')
      start = Time.now
      @redis_pool.connection do |redis|
        redis.pipelined do

          config.resolvers.each do |name, resolver|
            key = "dns_stats:#{name}"
            resolver.reset_log.each do |e|
              e[0] = e[0].to_f
              redis.rpush(key, e.join(','))
            end
            redis.ltrim key, 0, RESPONSE_STATS_MAX_LENGTH - 1
          end

          @stats.each do |key|
            redis.incr(key)
          end
          @stats.clear

        end
      end
      @logger.debug("publishing stats done: #{Time.now - start}")
    rescue IOError, Redis::BaseConnectionError => e
      @logger.warn("failed to publish stats #{e.message}")
    end

    # Resolve queries from the Redis queue 'dns_query'
    def resolve(id, name_server, names)
      @logger.debug("resolve request #{id}: #{names} @ #{name_server}")

      resolver = Resolver.new([[:udp, name_server, 53]], {}, nil)

      responses = names.map do |name|
        split = name.split(':')
        if split.length == 1
          resource_class = 'A'
        else
          resource_class = split[0]
          name = split[1]
        end
        response = resolver.query(name, resource_class == 'A' ? Resolv::DNS::Resource::IN::A : Resolv::DNS::Resource::IN::AAAA)
        if !response
          ''
        elsif response.answer && !response.answer.empty?
          "#{response.rcode},#{resource_class},#{response.answer[0][0]},#{response.answer[0][2].address}"
        else
          "#{response.rcode}"
        end
      end

      log = resolver.reset_log.map do |e|
        e[0] = e[0].to_f
        e.join(',')
      end

      result = { responses: responses, log: log }.to_json

      @logger.debug("resolved request #{id} to: #{result}")
      @redis_pool.connection do |redis|
        redis.pipelined do |redis|
          key = "dns_response:#{id}"
          redis.rpush(key, result)
          redis.expire(key, 300)
        end
      end
    rescue IOError, Redis::BaseConnectionError => e
      @logger.warn("failed to store result #{id}: #{e.message}")
    end

    private

    def respond(transaction, resource_class, record, ttl)
      if record
        transaction.respond!(record, {ttl: ttl})
      else
        transaction.fail!(:NoError)
      end
      if @config.name_server_name && @config.local_records[resource_class][@config.name_server_name]
        name = Resolv::DNS::Name.create @config.name_server_name
        ip = @config.local_records[resource_class][@config.name_server_name]
        transaction.respond!(Resolv::DNS::Name.create(name), { section: 'authority', resource_class: Resolv::DNS::Resource::IN::NS, ttl: LOCAL_TTL })
        transaction.respond!(ip, { name: name, section: 'additional', resource_class: resource_class, ttl: LOCAL_TTL })
      end
      return 1
    end

    def process_filtered_peer(name, resource_class, transaction, peer, stats_key_prefix)
      decision = filter(peer, name)
      return nil unless decision
      if decision.size == 2
        @stats << "#{stats_key_prefix}:blocked_queries:#{decision[1]}"
        @stats << "stats_total:dns:blocked_queries:#{decision[1]}"
      end
      if decision[0].is_a? String
        return respond(transaction, resource_class, decision[0], BLOCK_TTL) if resource_class == Resolv::DNS::Resource::IN::A
        return respond(transaction, resource_class, nil, BLOCK_TTL) if resource_class == Resolv::DNS::Resource::IN::AAAA
        return transaction.fail!(:NXDomain)
      end
      return transaction.fail!(decision[0]) if decision[0] != :Service_Error
      transaction.fail!(:ServFail) if @config.filtered_peers[peer]
    end

    def filter(peer, name)
      context = Async::Task.current
      begin
        context.timeout(3) do
          query_blacklist_service(peer, name)
        end
      rescue Async::TimeoutError, IOError, Errno::ECONNREFUSED
        @logger.warn "Error querying blacklist filter: \"#{$!}\""
        return [:Service_Error]
      end
    end

    def query_blacklist_service(peer, name)
      t = Time.now
      endpoint = Async::IO::Endpoint.udp('127.0.0.1', 7777)
      result = endpoint.connect do |socket|
        query = "#{peer} dns #{name} -\n"
        @logger.debug("querying blacklist filter: #{query.strip}")
        socket.send(query, 0)
        response = socket.recv(1024).strip!
        @logger.debug("response: #{response}")
        map_blacklist_query_response response
      end
      @logger.debug("blacklist filter took #{Time.now - t}s")
      return result
    end

    def map_blacklist_query_response(response)
      response = response.split(/[,= ]/)
      blocked = response[0] == 'OK'
      return nil if !blocked
      return [:NXDomain, response[3]]  if response.size < 7
      return [response[6].to_sym, response[3]] if response[6][0] == ':'
      return [response[6], response[3]]
    end

    def create_resolver(config, cache)
      options = config[:options] || {}

      if (options[:order])
        options[:order] = options[:order].to_sym
      end

      name_servers = config[:nameServers].map do |r|
        [ r[:protocol].downcase.to_sym, r[:address], r[:port] ]
      end

      Resolver.new(name_servers, options, cache)
    end

    class Resolver < Async::DNS::Resolver

      attr_reader :counter

      def initialize(nameservers, options, cache)
        super(nameservers, { timeout: 3 })
        @nameservers = nameservers
        @cache = cache
        @log = []
        @options = options
      end

      def query(name, resource_class = Resolv::DNS::Resource::IN::A, options = {})
        key = resource_class.to_s + '::' + name
        cached = @cache.get(key) if @cache
        if cached
          @log << [Time.now, 'cache', :valid]
          cached.update_ttl
          @logger.debug("returning cached response #{cached.response.inspect}")
          return cached.response
        end

        options = @options.merge(options)
        options[:log] = @log
        response = super(name, resource_class, options)

        if (!response)
          @logger.warn("no answer from upstream servers #{@nameservers}")
        elsif (@cache && response.rcode == Resolv::DNS::RCode::NoError && response.answer && response.answer.size > 0)
          answer_ttl = minimum_ttl(response)
          ttl = [answer_ttl, MINIMUM_TTL].max
          @logger.debug("caching response #{response.question} for #{ttl} seconds")
          @cache.put(key, CachedResponse.new(response), ttl)
        end

        response
      end

      def reset_log
        old_log = @log
        @log = []
        old_log
      end

      def minimum_ttl(response)
        response.answer.map { |a| a[1] }.min
      end

    end

    class CachedResponse

      attr_reader :response

      def initialize(response)
        @response = response
        @ttl_updated = Time.now
      end

      def update_ttl
        now = Time.now
        delta = now.tv_sec - @ttl_updated.tv_sec
        if (delta > 0)
          @response.answer.each do |answer|
            answer[1] = [0, answer[1] - delta].max;
          end
          @ttl_updated = now
        end
      end

    end
  end
end
