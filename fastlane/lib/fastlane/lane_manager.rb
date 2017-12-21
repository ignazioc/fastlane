require_relative 'lane_manager_base.rb'

module Fastlane
  class LaneManager < LaneManagerBase
    # @param platform The name of the platform to execute
    # @param lane_name The name of the lane to execute
    # @param parameters [Hash] The parameters passed from the command line to the lane
    # @param env Dot Env Information
    def self.cruise_lane(platform, lane, parameters = nil, env = nil)
      UI.user_error!("lane must be a string") unless lane.kind_of?(String) or lane.nil?
      UI.user_error!("platform must be a string") unless platform.kind_of?(String) or platform.nil?
      UI.user_error!("parameters must be a hash") unless parameters.kind_of?(Hash) or parameters.nil?

      ff = Fastlane::FastFile.new(FastlaneCore::FastlaneFolder.fastfile_path)

      is_platform = false
      begin
        is_platform = ff.is_platform_block?(lane)
      rescue # rescue, because this raises an exception if it can't be found at all
      end

      unless is_platform
        # maybe the user specified a default platform
        # We'll only do this, if the lane specified isn't a platform, as we want to list all platforms then

        # Make sure that's not a lane without a platform
        unless ff.runner.available_lanes.include?(lane)
          platform ||= Actions.lane_context[Actions::SharedValues::DEFAULT_PLATFORM]
        end
      end

      if !platform and lane
        # Either, the user runs a specific lane in root or want to auto complete the available lanes for a platform
        # e.g. `fastlane ios` should list all available iOS actions
        if ff.is_platform_block?(lane)
          platform = lane
          lane = nil
        end
      end

      platform, lane = choose_lane(ff, platform) unless lane

      FastlaneCore.session.is_fastfile = true

      # xcodeproj has a bug in certain versions that causes it to change directories
      # and not return to the original working directory
      # https://github.com/CocoaPods/Xcodeproj/issues/426
      # Setting this environment variable causes xcodeproj to work around the problem
      ENV["FORK_XCODE_WRITING"] = "true" unless platform == 'android'

      load_dot_env(env)

      started = Time.now
      e = nil
      begin
        ff.runner.execute(lane, platform, parameters)
      rescue Exception => ex # rubocop:disable Lint/RescueException
        # We also catch Exception, since the implemented action might send a SystemExit signal
        # (or similar). We still want to catch that, since we want properly finish running fastlane
        # Tested with `xcake`, which throws a `Xcake::Informative` object

        print_lane_context
        UI.error ex.to_s if ex.kind_of?(StandardError) # we don't want to print things like 'system exit'
        e = ex
      end

      # After running the lanes, since skip_docs might be somewhere in-between
      Fastlane::DocsGenerator.run(ff) unless skip_docs?

      duration = ((Time.now - started) / 60.0).round

      finish_fastlane(ff, duration, e)

      return ff
    end

    def self.skip_docs?
      Helper.test? || FastlaneCore::Env.truthy?("FASTLANE_SKIP_DOCS")
    end

    # All the finishing up that needs to be done
    def self.finish_fastlane(ff, duration, error)
      # Finished with all the lanes
      Fastlane::JUnitGenerator.generate(Fastlane::Actions.executed_actions)
      print_table(Fastlane::Actions.executed_actions)

      Fastlane::PluginUpdateManager.show_update_status

      if error
        UI.error 'fastlane finished with errors'
        raise error
      elsif duration > 5
        UI.success "fastlane.tools just saved you #{duration} minutes! 🎉"
      else
        UI.success 'fastlane.tools finished successfully 🎉'
      end
    end

    # Lane chooser if user didn't provide a lane
    # @param platform: is probably nil, but user might have called `fastlane android`, and only wants to list those actions
    def self.choose_lane(ff, platform)
      available = []

      # nil is the key for lanes that are not under a specific platform
      lane_platforms = [nil] + Fastlane::SupportedPlatforms.all
      lane_platforms.each do |p|
        available += ff.runner.lanes[p].to_a.reject { |lane| lane.last.is_private }
      end

      if available.empty?
        UI.user_error! "It looks like you don't have any lanes to run just yet. Check out how to get started here: https://github.com/fastlane/fastlane 🚀"
      end

      rows = []
      available.each_with_index do |lane, index|
        rows << [index + 1, lane.last.pretty_name, lane.last.description.join("\n")]
      end

      rows << [0, "cancel", "No selection, exit fastlane!"]

      table = Terminal::Table.new(
        title: "Available lanes to run",
        headings: ['Number', 'Lane Name', 'Description'],
        rows: FastlaneCore::PrintTable.transform_output(rows)
      )

      UI.message "Welcome to fastlane! Here's what your app is setup to do:"

      puts table

      i = UI.input "Which number would you like run?"

      i = i.to_i - 1
      if i >= 0 && available[i]
        selection = available[i].last.pretty_name
        UI.important "Running lane `#{selection}`. Next time you can do this by directly typing `fastlane #{selection}` 🚀."
        platform = selection.split(' ')[0]
        lane_name = selection.split(' ')[1]

        unless lane_name # no specific platform, just a root lane
          lane_name = platform
          platform = nil
        end

        return platform, lane_name # yeah
      else
        UI.user_error! "Run `fastlane` the next time you need to build, test or release your app 🚀"
      end
    end
  end
end
