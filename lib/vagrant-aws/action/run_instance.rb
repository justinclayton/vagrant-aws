require "log4r"

require 'vagrant/util/retryable'

require 'vagrant-aws/util/timer'

module VagrantPlugins
  module AWS
    module Action
      # This runs the configured instance.
      class RunInstance
        include Vagrant::Util::Retryable

        def initialize(app, env)
          @app    = app
          @logger = Log4r::Logger.new("vagrant_aws::action::run_instance")
        end

        def call(env)
          # Initialize metrics if they haven't been
          env[:metrics] ||= {}

          # Get the region we're going to booting up in
          region = env[:machine].provider_config.region

          # Get the configs
          region_config      = env[:machine].provider_config.get_region_config(region)
          ami                = region_config.ami
          availability_zone  = region_config.availability_zone
          instance_type      = region_config.instance_type
          ssh_port           = region_config.ssh_port
          keypair            = region_config.keypair_name
          private_ip_address = region_config.private_ip_address
          security_groups    = region_config.security_groups
          subnet_id          = region_config.subnet_id
          tags               = region_config.tags
          ebs_volume         = region_config.ebs_volume

          # If there is no keypair then warn the user
          if !keypair
            env[:ui].warn(I18n.t("vagrant_aws.launch_no_keypair"))
          end

          # If there is a subnet ID then warn the user
          if subnet_id
            env[:ui].warn(I18n.t("vagrant_aws.launch_vpc_warning"))
          end

          # Launch!
          env[:ui].info(I18n.t("vagrant_aws.launching_instance"))
          env[:ui].info(" -- Type: #{instance_type}")
          env[:ui].info(" -- AMI: #{ami}")
          env[:ui].info(" -- Region: #{region}")
          env[:ui].info(" -- Availability Zone: #{availability_zone}") if availability_zone
          env[:ui].info(" -- SSH Port: #{ssh_port}") if ssh_port
          env[:ui].info(" -- Keypair: #{keypair}") if keypair
          env[:ui].info(" -- Subnet ID: #{subnet_id}") if subnet_id
          env[:ui].info(" -- Private IP: #{private_ip_address}") if private_ip_address
          env[:ui].info(" -- Security Groups: #{security_groups.inspect}") if !security_groups.empty?

          begin
            options = {
              :availability_zone  => availability_zone,
              :flavor_id          => instance_type,
              :image_id           => ami,
              :key_name           => keypair,
              :ssh_port           => ssh_port,
              :private_ip_address => private_ip_address,
              :subnet_id          => subnet_id,
              :tags               => tags
            }

            if !security_groups.empty?
              security_group_key = options[:subnet_id].nil? ? :groups : :security_group_ids
              options[security_group_key] = security_groups
            end

            server = env[:aws_compute].servers.create(options)
          rescue Fog::Compute::AWS::NotFound => e
            # Invalid subnet doesn't have its own error so we catch and
            # check the error message here.
            if e.message =~ /subnet ID/
              raise Errors::FogError,
                :message => "Subnet ID not found: #{subnet_id}"
            end

            raise
          rescue Fog::Compute::AWS::Error => e
            raise Errors::FogError, :message => e.message
          end

          # Immediately save the ID since it is created at this point.
          env[:machine].id = server.id

          # Wait for the instance to be ready first
          env[:metrics]["instance_ready_time"] = Util::Timer.time do
            env[:ui].info(I18n.t("vagrant_aws.waiting_for_ready"))
            retryable(:on => Fog::Errors::TimeoutError, :tries => 30) do
              # If we're interrupted don't worry about waiting
              next if env[:interrupted]

              # Wait for the server to be ready
              server.wait_for(2) { ready? }
            end
          end

          @logger.info("Time to instance ready: #{env[:metrics]["instance_ready_time"]}")

          if !env[:interrupted]
            env[:metrics]["instance_ssh_time"] = Util::Timer.time do
              # Wait for SSH to be ready.
              env[:ui].info(I18n.t("vagrant_aws.waiting_for_ssh"))
              while true
                # If we're interrupted then just back out
                break if env[:interrupted]
                break if env[:machine].communicate.ready?
                sleep 2
              end
            end

            @logger.info("Time for SSH ready: #{env[:metrics]["instance_ssh_time"]}")

            if ebs_volume
              env[:ui].info("Attaching EBS volume #{ebs_volume[:volume_id]} to instance as #{ebs_volume[:device_name]}...")
              env[:aws_compute].attach_volume(env[:machine].id, ebs_volume[:volume_id], ebs_volume[:device_name])
            end

            # Ready and booted!
            env[:ui].info(I18n.t("vagrant_aws.ready"))
          end

          # Terminate the instance if we were interrupted
          terminate(env) if env[:interrupted]

          @app.call(env)
        end

        def recover(env)
          return if env["vagrant.error"].is_a?(Vagrant::Errors::VagrantError)

          if env[:machine].provider.state.id != :not_created
            # Undo the import
            terminate(env)
          end
        end

        def terminate(env)
          destroy_env = env.dup
          destroy_env.delete(:interrupted)
          destroy_env[:config_validate] = false
          destroy_env[:force_confirm_destroy] = true
          env[:action_runner].run(Action.action_destroy, destroy_env)
        end
      end
    end
  end
end
