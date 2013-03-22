module VagrantPlugins
  module Salt
    class Provisioner < Vagrant.plugin("2", :provisioner)

      def configure(config)
      end

      def provision
        upload_configs
        upload_keys
        run_bootstrap_script
        accept_keys
        call_highstate
      end

      ## Utilities
      def expanded_path(rel_path)
        Pathname.new(rel_path).expand_path(@machine.env.root_path)
      end

      def binaries_found()
        ## Determine States, ie: install vs configure
        desired_binaries = []
        if !@no_minion
          desired_binaries.push('salt-minion')
          desired_binaries.push('salt-call')
        end

        if @install_master
          desired_binaries.push('salt-master')
        end

        if @install_syndic
          desired_binaries.push('salt-syndic')
        end

        found = true
        for binary in desired_binaries
          @machine.env.ui.info "Checking if %s is installed" % binary
          if !@machine.communicate.test("which %s" % binary)
            @machine.env.ui.info "%s was not found." % binary
            found = false
          else
            @machine.env.ui.info "%s found" % binary
          end
        end

        return found
      end

      def need_configure()
        @minion_config or @minion_key
      end

      def need_install()
        if @always_install
          return true
        else
          return !binaries_found()
        end
      end

      def temp_config_dir()
        return @temp_config_dir || "/tmp"
      end

      # Generates option string for bootstrap script
      def bootstrap_options(install, configure, config_dir)
        options = ""

        ## Any extra options passed to bootstrap
        if @bootstrap_options
          options = "%s %s" % [options, @bootstrap_options]
        end

        if configure
          options = "%s -c %s" % [options, config_dir]
        end

        if configure and !install
          options = "%s -C" % options
        else

          if @install_master
            options = "%s -M" % options
          end

          if @install_syndic
            options = "%s -S" % options
          end

          if @no_minion
            options = "%s -N" % options
          end

          if @install_type
            options = "%s %s" % [options, @install_type]
          end

          if @install_args
            options = "%s %s" % [options, @install_args]
          end 
        end

        return options
      end


      ## Actions
      # Copy master and minion configs to VM
      def upload_configs()
        if @minion_config
          @machine.env.ui.info "Copying salt minion config to vm."
          @machine.communicate.upload(expanded_path(@minion_config).to_s, temp_config_dir + "/minion")
        end

        if @master_config
          @machine.env.ui.info "Copying salt master config to vm."
          @machine.communicate.upload(expanded_path(@master_config).to_s, temp_config_dir + "/master")
        end
      end

      # Copy master and minion keys to VM
      def upload_keys()
        if @minion_key and @minion_pub
          @machine.env.ui.info "Uploading minion keys."
          @machine.communicate.upload(expanded_path(@minion_key).to_s, temp_config_dir + "/minion.pem")
          @machine.communicate.upload(expanded_path(@minion_pub).to_s, temp_config_dir + "/minion.pub")
        end

        if @master_key and @master_pub
          @machine.env.ui.info "Uploading master keys."
          @machine.communicate.upload(expanded_path(@master_key).to_s, temp_config_dir + "/master.pem")
          @machine.communicate.upload(expanded_path(@master_pub).to_s, temp_config_dir + "/master.pub")
        end
      end

      # Get bootstrap file location, bundled or custom
      def get_bootstrap()
        if @bootstrap_script
          bootstrap_abs_path = expanded_path(@bootstrap_script)
        else
          bootstrap_abs_path = Pathname.new("../../../scripts/bootstrap-salt.sh").expand_path(__FILE__)
        end
        return bootstrap_abs_path
      end

      # Determine if we are configure and/or installing, then do either
      def run_bootstrap_script()
        install = need_install()
        configure = need_configure()
        config_dir = temp_config_dir()
        options = bootstrap_options(install, configure, config_dir)

        if configure or install

          if configure and !install
            @machine.env.ui.info "Salt binaries found. Configuring only."
          else
            @machine.env.ui.info "Bootstrapping Salt... (this may take a while)"
          end
          
          bootstrap_path = get_bootstrap()
          bootstrap_destination = File.join(config_dir, "bootstrap_salt.sh")
          @machine.communicate.upload(bootstrap_path.to_s, bootstrap_destination)
          @machine.communicate.sudo("chmod +x %s" % bootstrap_destination)
          bootstrap = @machine.communicate.sudo("%s %s" % [bootstrap_destination, options]) do |type, data|
            if data[0] == "\n"
              # Remove any leading newline but not whitespace. If we wanted to
              # remove newlines and whitespace we would have used data.lstrip
              data = data[1..-1]
            end
            if @verbose
              @machine.env.ui.info(data.rstrip)
            end
          end
          if !bootstrap
            raise SaltError, :bootstrap_failed
          end

          if configure and !install
            @machine.env.ui.info "Salt successfully configured!"
          elsif configure and install
            @machine.env.ui.info "Salt successfully configured and installed!"
          elsif !configure and install
            @machine.env.ui.info "Salt successfully installed!"
          end
        
        else
          @machine.env.ui.info "Salt did not need installing or configuring."
        end
      end

      def accept_keys()
        if @accept_keys
          if !@machine.communicate.test("which salt-key")
            @machine.env.ui.info "Salt-key not installed!"
          else
            @machine.env.ui.info "Waiting for minion key..."
            key_staged = false
            attempts = 0
            while !key_staged
              attempts += 1 
              @machine.communicate.sudo("salt-key -l pre | wc -l") do |type, output|
                begin
                  output = Integer(output)
                  if output > 1
                    key_staged = true
                  end
                rescue
                end
              end
              sleep 1
              if attempts > 10
                raise SaltError, :not_received_minion_key
              end
            end

            @machine.env.ui.info "Accepting minion key."
            @machine.communicate.sudo("salt-key -A")
          end
        end
      end

      def call_highstate()
        if @run_highstate
          @machine.env.ui.info "Calling state.highstate... (this may take a while)"
          @machine.communicate.sudo("salt-call saltutil.sync_all")
          @machine.communicate.sudo("salt-call state.highstate -l debug") do |type, data|
            if @verbose
              @machine.env.ui.info(data)
            end
          end
        else
          @machine.env.ui.info "run_highstate set to false. Not running state.highstate."
        end
      end

    end
  end
end