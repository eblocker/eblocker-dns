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
require 'set'

#module Eblocker::Dns

class Cache

  def initialize(max_size)
    @max_size = max_size
    @cache = Hash.new
    @ttl = SortedSet.new
  end

  def get(key, t = Time.now)
    entry = @cache.delete(key)

    return nil unless entry

    if (entry.is_expired(t))
      @cache.delete(entry.key)
      @ttl.delete(entry)
      return nil
    end

    @cache[key] = entry
    entry.value
  end

  def put(key, value, ttl, t = Time.now)
    if (@cache.size == @max_size)
      evict!
    end

    # ensure ttl entry is removed if this is a refresh
    replaced = @cache.delete(key)
    @ttl.delete(replaced) if replaced

    entry = Entry.new(key, value, t + ttl)
    @cache[key] = entry
    @ttl.add(entry)
  end

  def clear
    @cache.clear
    @ttl.clear
  end

  def size
    @cache.size
  end

  def evict!(t = Time.now)
    # first try to evict an expired entry
    e = @ttl.first
    if (e.is_expired(t))
      @cache.delete(e.key)
      @ttl.delete(e)
      return
    end

    # cache is still full so just remove least used element
    e = @cache.shift
    @ttl.delete(e[1])
  end

  def to_s
    t = Time.now
    s = "==================================\n"
    s += "- cache #{@cache.size} ------------\n"
    @cache.each do |k, v|
      s += "#{v.key} #{v.valid_until - t}\n"
    end
    s += "- ttl #{@ttl.size} --------------\n"
    @ttl.each do |v|
      s += "#{v.key} #{v.valid_until - t}\n"
    end
    s += "==================================\n"
  end

  class Entry
    attr_reader :key
    attr_reader :value
    attr_reader :valid_until

    def initialize(key, value, valid_until)
      @key = key
      @value = value
      @valid_until = valid_until
    end

    def is_expired(now = Time.now)
      now > valid_until
    end

    def <=>(other)
      c = valid_until <=> other.valid_until
      return c unless c == 0
      key <=> other.key
    end
  end
end

#end

