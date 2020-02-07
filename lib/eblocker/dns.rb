#!/usr/bin/env ruby
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

require 'eblocker/dns/version'
require 'eblocker/dns/server'
require 'eblocker/dns/config-listener'
require 'eblocker/async/redis'
require 'eblocker/async/redis/async-io'
require 'eblocker/async/redis/pool'
require 'process/daemon'

module Eblocker::Dns

  class Daemon < Process::Daemon

    DEVICE = 'eth0'

    def run
      Async.logger.level = Logger::INFO

      Async::Reactor.run do |task|
        redis_pool = Eblocker::Async::Redis::Pool.new({ :host => '127.0.0.1', :port => '6379'}, Async.logger)

        server = Server.new([[:udp, '::', 5300]], redis_pool)
        ConfigChannelListener.new(redis_pool, server, Async.logger).listen
        server.run

        task.async do |t|
          while true
            begin
              redis_pool.connection do |redis|
                query = redis.blpop('dns_query')[1].split(',')
                server.resolve(query[0], query[1], query.drop(2))
              end
            rescue IOError, Redis::BaseConnectionError => e
              Async.logger.warn "blocking pop failed: #{e.message}"
              t.sleep(10)
            end
          end
        end
      end
    end

    def name
      'eblocker-dns'
    end
  end

  Daemon.daemonize
end
