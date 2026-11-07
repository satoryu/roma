require 'singleton'
require 'roma/configuration'

module Roma
  class DNSCache
    include Singleton

    def initialize
      @@addrs = {}
      @@enabled_caching = Roma.config.connection.dns_caching
    end

    def resolve_name(host)
      return host unless @@enabled_caching

      unless @@addrs.include?(host)
        res = TCPSocket.gethostbyname(host)
        @@addrs[host] = res[3]
      end
      @@addrs[host]
    end

    def disable_dns_cache
      @@enabled_caching = false
      @@addrs.clear
    end

    def enable_dns_cache
      @@enabled_caching = true
    end

    def stat
      ret = {}
      ret['dns_caching'] = @@enabled_caching
      ret
    end
  end
end
