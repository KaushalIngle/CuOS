def chutney_src_dir
  "#{GIT_DIR}/submodules/chutney"
end

def chutney_status_log(cmd)
  action = case cmd
           when 'start'
             'starting'
           when 'stop'
             'stopping'
           when 'stop_old'
             'cleaning up old instance'
           when 'configure'
             'configuring'
           when 'wait_for_bootstrap'
             'waiting for bootstrap (might take a few minutes)'
           when 'done'
             'started!'
           else
             return
           end
  puts("Chutney Tor network simulation: #{action} ...")
end

# XXX: giving up on a few worst offenders for now
# rubocop:disable Metrics/AbcSize
# rubocop:disable Metrics/CyclomaticComplexity
# rubocop:disable Metrics/MethodLength
# rubocop:disable Metrics/PerceivedComplexity
def ensure_chutney_is_running
  # Ensure that a fresh chutney instance is running, and that it will
  # be cleaned upon exit. We only do it once, though, since the same
  # setup can be used throughout the same test suite run.
  return if $chutney_initialized

  chutney_listen_address = $vmnet.bridge_ip_addr
  chutney_script = "#{chutney_src_dir}/chutney"
  assert(
    File.executable?(chutney_script),
    "It does not look like '#{chutney_src_dir}' is the Chutney source tree"
  )
  network_definition = "#{GIT_DIR}/features/chutney/test-network"
  env = {
    'CHUTNEY_LISTEN_ADDRESS' => chutney_listen_address,
    'CHUTNEY_DATA_DIR'       => "#{$config['TMPDIR']}/chutney-data",
    # The default value (60s) is too short for "chutney wait_for_bootstrap"
    # to succeed reliably.
    'CHUTNEY_START_TIME'     => '600',
  }

  chutney_data_dir_cleanup = proc do
    if File.directory?(env['CHUTNEY_DATA_DIR'])
      FileUtils.rm_r(env['CHUTNEY_DATA_DIR'])
    end
  end

  chutney_cmd = proc do |cmd|
    chutney_status_log(cmd)
    cmd = 'stop' if cmd == 'stop_old'
    Dir.chdir(chutney_src_dir) do
      cmd_helper([chutney_script, cmd, network_definition], env: env)
    end
  end

  # After an unclean shutdown of the test suite (e.g. Ctrl+C) the
  # tor processes are left running, listening on the same ports we
  # are about to use. If chutney's data dir also was removed, this
  # will prevent chutney from starting the network unless the tor
  # processes are killed manually.
  begin
    cmd_helper(['pkill', '--full', '--exact',
                "tor -f #{env['CHUTNEY_DATA_DIR']}/nodes/.*/torrc --quiet",])
  rescue StandardError
    # Nothing to kill
  end

  if KEEP_CHUTNEY
    begin
      chutney_cmd.call('start')
    rescue Test::Unit::AssertionFailedError
      if File.directory?(env['CHUTNEY_DATA_DIR'])
        raise 'You are running with --keep-snapshots or --keep-chutney, ' \
              'but Chutney failed ' \
              'to start with its current data directory. To recover you ' \
              "likely want to delete '#{env['CHUTNEY_DATA_DIR']}' and " \
              'all test suite snapshots and then start over.'
      else
        chutney_cmd.call('configure')
        chutney_cmd.call('start')
      end
    end
  else
    chutney_cmd.call('stop_old')
    chutney_data_dir_cleanup.call
    chutney_cmd.call('configure')
    chutney_cmd.call('start')
  end

  # Documentation: submodules/chutney/README, "Waiting for the network" section
  chutney_cmd.call('wait_for_bootstrap')

  at_exit do
    chutney_cmd.call('stop')
    chutney_data_dir_cleanup.call unless KEEP_CHUTNEY
  end

  # We have to sanity check that all nodes are running because
  # `chutney start` will return success even if some nodes fail.
  status = chutney_cmd.call('status')
  match = Regexp.new('^(\d+)/(\d+) nodes are running$').match(status)
  assert_not_nil(match, "Chutney's status did not contain the expected " \
                        'string listing the number of running nodes')
  running, total = match[1, 2].map(&:to_i)
  assert_equal(
    total, running, "Chutney is only running #{running}/#{total} nodes"
  )

  $chutney_initialized = true
  chutney_status_log('done')
end
# rubocop:enable Metrics/AbcSize
# rubocop:enable Metrics/CyclomaticComplexity
# rubocop:enable Metrics/MethodLength
# rubocop:enable Metrics/PerceivedComplexity

def configure_simulated_Tor_network # rubocop:disable Naming/MethodName
  # At the moment this function essentially assumes that we boot with 'the
  # network is unplugged', run this function, and then 'the network is
  # plugged'. I believe we can make this pretty transparent without
  # the need of a dedicated step by using tags (e.g. @fake_tor or
  # whatever -- possibly we want the opposite, @real_tor,
  # instead).
  #
  # There are two time points where we for a scenario must ensure that
  # the client configuration below is enabled if and only if the
  # scenario is tagged, and that is:
  #
  # 1. During a proper boot, as soon as the remote shell is up in the
  #    'the computer boots Tails' step.
  #
  # 2. When restoring a snapshot, in restore_background().
  #
  # If we do this, it doesn't even matter if a snapshot is made of an
  # untagged scenario (without the conf), and we later restore it with
  # a tagged scenario.
  #
  # Note: We probably have to clear the /var/lib/tor data dir when we
  # switch mode. Possibly there are other such problems that make this
  # abstraction impractical and it's better that we avoid it an go
  # with the more explicit, step-based approach.

  ensure_chutney_is_running
  # Most of these lines are taken from chutney's client template.
  client_torrc_lines = [
    'TestingTorNetwork 1',
    'AssumeReachable 1',
    'PathsNeededToBuildCircuits 0.67',
    'TestingDirAuthVoteExit *',
    'TestingDirAuthVoteGuard *',
    'TestingDirAuthVoteHSDir *',
    'TestingMinExitFlagThreshold 0',
    'V3AuthNIntervalsValid 2',
    # Enabling TestingTorNetwork disables ClientRejectInternalAddresses
    # so the Tor client will happily try LAN connections. Coupled with
    # that TestingTorNetwork is enabled on all exits, and their
    # ExitPolicyRejectPrivate is disabled, we will allow exiting to
    # LAN hosts. We have at least one test that tries to make sure
    # that is *not* possible (Scenario: The Tor Browser cannot access
    # the LAN) so we cannot allow it. We'll have to rethink all this
    # if we ever want to run all services locally as well (#9520).
    'ClientRejectInternalAddresses 1',
  ]
  # We run one client in chutney so we easily can grep the generated
  # DirAuthority lines and use them.
  client_torrcs = Dir.glob(
    "#{$config['TMPDIR']}/chutney-data/nodes/*client/torrc"
  )
  dir_auth_lines = File.open(client_torrcs.first) do |f|
    f.grep(/^(Alternate)?(Dir|Bridge)Authority\s/)
  end
  client_torrc_lines.concat(dir_auth_lines)
  $vm.file_append('/etc/tor/torrc', client_torrc_lines)

  # Since we use a simulated Tor network (via Chutney) we have to
  # switch to its default bridges.
  default_bridges_path = '/usr/share/tails/tca/default_bridges.txt'
  $vm.file_overwrite(default_bridges_path, '')
  chutney_bridges('obfs4', chutney_tag: 'defbr').each do |bridge|
    $vm.file_append(default_bridges_path, bridge[:line])
  end

  $vm.execute_successfully('systemctl restart tor@default.service')
end
