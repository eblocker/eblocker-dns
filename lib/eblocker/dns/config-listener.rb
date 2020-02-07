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
require 'redis'

module Eblocker::Dns

  class ConfigChannelListener

    def initialize(redis_pool, server, logger)
      @redis_pool = redis_pool
      @server = server
      @logger = logger
    end

    def listen(task: Async::Task.current)
      task.async do |t|
        while true
          begin
            @logger.debug('subscribing to "dns_config"')
            @redis_pool.connection do |redis|
              redis.subscribe('dns_config') do |event|
                event.message do |channel, body|
                  handle_message(body)
                end
              end
            end
          rescue IOError, Redis::BaseConnectionError => e
            @logger.warn "channel lost: #{e.message}"
            t.sleep(10)
          end
        end
      end
    end

    def handle_message(message)
      command = message.split(' ')
      case command[0]
        when 'update'
          @server.load_config
        when 'flush'
          @server.flush_cache
        when 'stats'
          @server.publish_stats
        when 'dump_cache'
          @server.dump_cache
        when 'dump_stats'
          @server.dump_stats
        else
          @logger.warn "ignoring unknown command: #{command[0]}"
      end
    end

  end
end
