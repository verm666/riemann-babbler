#encoding: utf-8

require File.expand_path('../support/plugin_helpers', __FILE__)
require 'riemann/client'
require 'open3'
require 'timeout'
require 'rest_client'
require 'socket'
require 'net/ping'
require 'sequel'
require File.expand_path('../support/monkey_patches', __FILE__)


# Базовое описание плагина
module Riemann
  class Babbler

    def self.registered_plugins
      @plugins ||= []
    end

    def self.inherited( klass )
      registered_plugins << klass
    end

    attr_reader :logger
    attr_reader :riemann
    alias :r :riemann
    attr_reader :hostname

    def initialize( configatron, logger, riemann )
      @configatron = configatron
      @logger = logger
      @riemann = riemann
      @storage = Hash.new
      @hostname = get_hostname
      init
      plugin.set_default(:interval, configatron.riemann.interval)
    end

    # Доступ к конфигу определенного плагина
    def plugin
      plugin_name = self.class.name.split('::').last.gsub( /(\p{Lower})(\p{Upper})/, "\\1_\\2" ).downcase
      options.plugins.send plugin_name
    end

    def options
      @configatron
    end
    alias :opts :options

    def report(event)
      report_with_diff(event) and return if event[:as_diff]
      # если нет event[:state] то попробовать его добавить
      unless event[:state]
        event[:state] = state(event[:metric]) unless plugin.states.critical.nil?
      end
      event[:metric] = event[:metric].round(2) if event[:metric].kind_of? Float
      event[:tags] = options.riemann.tags unless options.riemann.tags.nil?
      event[:host] =  hostname
      logger.debug "Report status: #{event.inspect}"
      riemann << event
    end

    def report_with_diff(event)
      current_metric = event[:metric]
      event[:metric] = current_metric - @storage[ event[:service] ] if @storage.has_key? event[:service]
      @storage[ event[:service] ] = current_metric
      event.delete(:as_diff)
      report(event)
    end

    def get_hostname
      # разбор fqdn
      if options.riemann.use_fqdn.nil? || options.riemann.use_fqdn == false
        hostname = File.read('/proc/sys/kernel/hostname').strip.downcase
      else
        hostname = Socket.gethostbyname(Socket.gethostname).first
      end
      # разбор инсталяции
      if options.riemann.installation.nil?
        hostname += options.riemann.suffix unless options.riemann.suffix.nil?
      else
        hostname += ( '.' + options.riemann.installation )
      end
      hostname = options.riemann.prefix + hostname unless options.riemann.prefix.nil?
      hostname
    end

    # не запускаем плагин есть 
    def run_plugin
      if plugin.run.nil?
        true
      else
        plugin.run == true ? true : false
      end
    end

    # Переодически вызываемое действие
    def tick
      posted_array = collect
      posted_array = posted_array.class == Array ? posted_array : [ posted_array ]
      posted_array.uniq.each { |event| report event }
    end

    # Plugin init
    def init
    end

    def run
      # выйти если run_plugin не равен true
      return 0 unless run_plugin
      t0 = Time.now
      loop do
        begin
          tick
        rescue => e
          logger.error "Plugin #{self.class.name} : #{e.class} #{e}\n#{e.backtrace.join "\n"}"
        end

        sleep(plugin.interval - ((Time.now - t0) % plugin.interval))
      end
    end

    # хелпер, описание статуса
    def state(my_state)
      return 'critical' if my_state.nil?
      if plugin.states.warning.nil?
        my_state >= plugin.states.critical ? 'critical' : 'ok'
      else
        case
          when my_state.between?(plugin.states.warning, plugin.states.critical)
            'warning'
          when my_state > plugin.states.warning
            'critical'
          else
            'ok'
        end
      end
    end

  end
end
