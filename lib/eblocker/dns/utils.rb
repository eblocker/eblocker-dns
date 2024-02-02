#
# Copyright 2024 eBlocker Open Source UG (haftungsbeschraenkt)
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

require 'socket'

module Eblocker::Dns
  class Utils
    def self.sort_ipv4_local_addresses_first(addresses)
      return addresses.sort_by {|address|
        ip = Addrinfo.ip(address)
        [
          ip.ipv4_private?() ? 0 : 1,  # first private addresses
          self.ipv4_linklocal?(address) ? 0 : 1, # second: link-local addresses
          ip.ipv4_loopback?() ? 1 : 0, # loopback addresses last
          ip.to_s() # then sort by the address itself
        ]
      }
    end

    def self.sort_ipv6_local_addresses_first(addresses)
      return addresses.sort_by {|address|
        ip = Addrinfo.ip(address)
        [
          ip.ipv6_unique_local?() ? 0 : 1,  # first unique local addresses (ULA)
          ip.ipv6_linklocal?() ? 0 : 1, # second: link-local addresses
          ip.ipv6_loopback?() ? 1 : 0, # loopback addresses last
          ip.to_s() # then sort by the address itself
        ]
      }
    end

    def self.ipv4_linklocal?(address) # for some reason this is missing in Addrinfo
      return address.start_with?('169.254.')
    end
  end
end
