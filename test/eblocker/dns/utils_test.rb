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

require 'minitest/autorun'
require 'bundler/setup'
require 'eblocker/dns/utils'

class UtilsTest < Minitest::Test
  def test_sort_ipv4
    unsorted = ['1.2.3.4', '127.0.0.1', '192.168.178.1', '10.10.10.10', '100.99.98.97', '169.254.7.3']
    sorted = ['10.10.10.10', '192.168.178.1', '169.254.7.3', '1.2.3.4', '100.99.98.97', '127.0.0.1']
    assert_equal(sorted, Eblocker::Dns::Utils.sort_ipv4_local_addresses_first(unsorted))
  end

  def test_sort_ipv6
    unsorted = ['2a04:a:b:c:1:2:3:4', 'fe80::a:b:c:d', '::1', 'fd00::1234:5678:90ab:cdef']
    sorted = ['fd00::1234:5678:90ab:cdef', 'fe80::a:b:c:d', '2a04:a:b:c:1:2:3:4', '::1']
    assert_equal(sorted, Eblocker::Dns::Utils.sort_ipv6_local_addresses_first(unsorted))
  end
end
