require 'socket'
require 'capistrano_dsl'
require 'marathon'
require 'centurion/service'

module Centurion
  class MesosService < Service
    extend ::Capistrano::DSL

    attr_accessor :instances, :min_health_capacity, :max_health_capacity, :executor,
                  :health_check, :health_checks
    attr_reader :env_vars, :cpu_shares, :memory, :image, :docker_labels

    def initialize(name, marathon_url)
      @name          = name
      @env_vars      = {}
      @docker_labels = {}
      @volumes       = []
      @port_bindings = []
      @cap_adds      = []
      @cap_drops     = []
      @network_mode  = 'bridge'
      @health_checks = []
      Marathon.url   = marathon_url
    end

    def self.from_env
      MesosService.new(fetch(:name), fetch(:marathon_url)).tap do |s|
        s.image = if fetch(:tag, nil)
          "#{fetch(:image, nil)}:#{fetch(:tag)}"
        else
          fetch(:image, nil)
        end

        health_checks = fetch(:health_checks, [
          {
            protocol: "HTTP",
            path: "/status/check",
            gracePeriodSeconds: 30,
            intervalSeconds: 3,
            portIndex: 0,
            timeoutSeconds: 3,
            maxConsecutiveFailures: 3            
          }
        ])

        s.instances           = fetch(:instances, 1)
        s.min_health_capacity = fetch(:min_health_capacity, 1)
        s.max_health_capacity = fetch(:max_health_capacity, 0.1)
        s.executor            = fetch(:executor, '/opt/gotools/nr-mesos-executor/nr-mesos-executor')
        s.cap_adds            = fetch(:cap_adds, [])
        s.cap_drops           = fetch(:cap_drops, [])
        s.dns                 = fetch(:dns, nil)
        s.extra_hosts         = fetch(:extra_hosts, nil)
        s.volumes             = fetch(:binds, [])
        s.port_bindings       = fetch(:port_bindings, [])
        s.network_mode        = fetch(:network_mode, 'BRIDGE')
        s.command             = fetch(:command, nil)
        s.memory              = fetch(:memory, 0)
        s.cpu_shares          = fetch(:cpu_shares, 0)
        s.health_check        = fetch(:health_check, 'http')
        s.health_checks       = health_checks

        s.add_env_vars(fetch(:env_vars, {}))
        s.add_docker_labels(fetch(:docker_labels, {}))

      end
    end

    def add_port_bindings(host_port, container_port, type = 'tcp', host_ip = nil)
      @port_bindings << PortBinding.new(host_port, container_port, type, host_ip)
    end

    def add_volume(host_volume, container_volume)
      @volumes << Volume.new(host_volume, container_volume)
    end

    def cpu_shares=(shares)
      begin
        Float(shares) != nil
      rescue
        raise ArgumentError, "invalid value for cgroup CPU constraint: #{shares}, value must be a between 0 and 18446744073709551615"
      end
      @cpu_shares = shares
    end

    def with_timeout timeout, &block
      begin
        Timeout::timeout(timeout) {
          yield
        }
      rescue Time::Error
        puts "** Timout. Cancelling deploy".red
        delete_app
      end
    end

    def attach_events &block
      wget_cmd = '/usr/local/bin/wget'
      wget_accept = '--header="Accept: text/event-stream"'
      event_path = '/v2/events'
      cmd = %Q< #{wget_cmd} #{wget_accept} #{Marathon.url}#{event_path} -qO->
      events = IO::popen(cmd, 'r+')
      while line = events.readline
        next if line =~ /^\r\n$/
        next if line =~ /^event:/
        json_event = line.gsub(/^data:\s+/,'')
        event_object = JSON.load(json_event)
        yield(event_object)
      end
    end

    def get_real_ports
      @port_bindings.inject([]) do |memo, binding|
        memo.push({
          :key => "label",
          :value => "ServicePort_#{binding.container_port}=#{binding.host_port}"
          })
      end
    end

    def get_docker_labels
      labels = []
      @docker_labels.each do |k,v|
        labels.push({
          :key => 'label',
          :value => "#{k}=#{v}"
          })
      end
      return labels
    end


    def centurion_to_mesos
      payload = {
        "id" => @name,
        "cpus" => @cpu_shares,
        "mem" => @memory,
        "instances" => @instances,
        "healthChecks" => @health_checks,
        "cmd" => nil,
        "upgradeStrategy" => {
          "minimumHealthCapacity" => @min_health_capacity,
          "maximumOverCapacity" => @max_health_capacity
        },
        "ports" => @port_bindings.map {|x| x.host_port},
        "env" => @env_vars,
        "container" => {
          :type => "DOCKER",
          :docker => {
            :image => @image,
            :network => @network_mode,
            :parameters => get_docker_labels.concat(get_real_ports),
            :portMappings => @port_bindings.inject([]) do |memo,binding|
              memo << {
                :containerPort => binding.container_port,
                :hostPort => 0,
                :servicePort => 0,
                :protocol => binding.type
              }
            end,
          }
        }
      }
      return payload
    end

    def is_a_uint64?(value)
      result = false
      if !value.is_a? Integer
        return result
      end
      if value < 0 || value > 0xFFFFFFFFFFFFFFFF
        return result
      end
      return true
    end

    class RestartPolicy < Struct.new(:name, :max_retry_count)
    end

    class Volume < Struct.new(:host_volume, :container_volume)
    end

    class PortBinding < Struct.new(:host_port, :container_port, :type, :host_ip)
    end

  end
end