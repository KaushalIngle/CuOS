When /^I see and accept the Unsafe Browser start verification$/ do
  @screen.wait('GnomeQuestionDialogIcon.png', 30)
  @screen.type(['Tab'], ['Return'])
end

def supported_torbrowser_locales
  localization_descriptions =
    "#{Dir.pwd}/config/chroot_local-includes/" \
    'usr/share/tails/browser-localization/descriptions'
  supported_locales = $vm.file_content(
    '/usr/share/tails/greeter/supported_languages'
  ).split
  File.read(localization_descriptions).split("\n").map do |line|
    # The line will be of the form "xx:YY" or "xx-YY:YY"
    locale = line.split(':').first.sub('-', '_')
    language = locale.split('_').first
    next unless supported_locales.include?(language)

    "#{locale}.utf8"
  end.compact
end

Then /^I start the Unsafe Browser in the "([^"]+)" locale$/ do |loc|
  step "I run \"LANG=#{loc} LC_ALL=#{loc} sudo unsafe-browser\" " \
       'in GNOME Terminal'
  step 'I see and accept the Unsafe Browser start verification'
end

Then /^I can start the Unsafe Browser in a few supported languages$/ do
  failed = []
  # We always want the locale which we verify the startup page warning
  # for, and one RTL locale ...
  locales = ['fr_FR.UTF-8', 'fa_IR.UTF-8']
  # ... then we just pick one *other* random non-English locale.
  locales += (supported_torbrowser_locales - locales - ['en_US.utf8'])
             .sample(1)
  locales.each do |lang|
    step "I start the Unsafe Browser in the \"#{lang}\" locale"
    begin
      step "the Unsafe Browser has started in the \"#{lang}\" locale"
    rescue StandardError
      failed << lang
    end
    begin
      step 'I kill the Unsafe Browser'
    rescue ExecutionFailedInVM
      # The Unsafe Browser wasn't running
    end
    step 'the Unsafe Browser chroot is torn down'
  end
  assert(failed.empty?,
         'Unsafe Browser failed to launch in the following locale(s): ' +
         failed.join(', '))
end

Then /^the Unsafe Browser has no add-ons installed$/ do
  step 'I open the address "about:addons" in the Unsafe Browser'
  step 'I see "UnsafeBrowserNoAddons.png" after at most 30 seconds'
end

Then /^the Unsafe Browser has only Firefox's default bookmarks configured$/ do
  info = xul_application_info('Unsafe Browser')
  # "Show all bookmarks"
  @screen.press('shift', 'ctrl', 'o')
  @screen.wait('UnsafeBrowserExportBookmarksButton.png', 20).click
  @screen.wait('UnsafeBrowserExportBookmarksButtonSelected.png', 20)
  @screen.wait('UnsafeBrowserExportBookmarksMenuEntry.png', 20).click
  @screen.wait('UnsafeBrowserExportBookmarksSavePrompt.png', 20)
  path = "/home/#{info[:user]}/bookmarks"
  @screen.paste(path)
  @screen.press('Return')
  chroot_path = "#{info[:chroot]}/#{path}.json"
  try_for(10) { $vm.file_exist?(chroot_path) }
  dump = JSON.parse($vm.file_content(chroot_path))

  def check_bookmarks_helper(bookmarks_children)
    mozilla_uris_counter = 0
    bookmarks_children.each do |h|
      h.each_pair do |k, v|
        if k == 'children'
          mozilla_uris_counter += check_bookmarks_helper(v)
        elsif k == 'uri'
          uri = v
          # rubocop:disable Style/GuardClause
          if uri.match("^https://(?:support|www)\.mozilla\.org/")
            mozilla_uris_counter += 1
          else
            raise "Unexpected Unsafe Browser bookmark for '#{uri}'"
          end
          # rubocop:enable Style/GuardClause
        end
      end
    end
    mozilla_uris_counter
  end

  mozilla_uris_counter = check_bookmarks_helper(dump['children'])
  assert_equal(5, mozilla_uris_counter,
               "Unexpected number (#{mozilla_uris_counter}) of mozilla " \
               'bookmarks')
  @screen.press('alt', 'F4')
end

Then /^the Unsafe Browser has a red theme$/ do
  @screen.wait('UnsafeBrowserRedTheme.png', 10)
end

Then /^the Unsafe Browser shows a warning as its start page(?: in the "([^"]+)" locale)?$/ do |locale|
  case locale
  # Use localized image for languages that have a translated version
  # of the Unsafe Browser homepage.
  when /\A([a-z]+)/
    localized_image = "UnsafeBrowserStartPage.#{Regexp.last_match(1)}.png"
    start_page_image = if File.exist?("#{OPENCV_IMAGE_PATH}/#{localized_image}")
                         localized_image
                       else
                         start_page_image = 'UnsafeBrowserStartPage.png'
                       end
  else
    start_page_image = 'UnsafeBrowserStartPage.png'
  end
  @screen.wait(start_page_image, 60)
end

Then /^the Unsafe Browser has started(?: in the "([^"]+)" locale)?$/ do |locale|
  if locale
    step 'the Unsafe Browser shows a warning as its start page in the ' \
         "\"#{locale}\" locale"
  else
    step 'the Unsafe Browser shows a warning as its start page'
  end
end

Then /^I see a warning about another instance already running$/ do
  @screen.wait('UnsafeBrowserWarnAlreadyRunning.png', 10)
end

Then /^I can start the Unsafe Browser again$/ do
  step 'I start the Unsafe Browser'
end

When /^I configure the Unsafe Browser to use a local proxy$/ do
  socksport_lines =
    $vm.execute_successfully('grep -w "^SocksPort" /etc/tor/torrc').stdout
  assert(socksport_lines.size >= 4, 'We got fewer than four Tor SocksPorts')
  proxy = socksport_lines.scan(/^SocksPort\s([^:]+):(\d+)/).sample
  proxy_host = proxy[0]
  proxy_port = proxy[1]

  debug_log('Configuring the Unsafe Browser to use a Tor SOCKS proxy ' \
            "(host=#{proxy_host}, port=#{proxy_port})")

  prefs = '/usr/share/tails/chroot-browsers/unsafe-browser/prefs.js'
  $vm.file_append(prefs, 'user_pref("network.proxy.type", 1);' + "\n")
  $vm.file_append(prefs,
                  "user_pref(\"network.proxy.socks\", \"#{proxy_host})\";\n")
  $vm.file_append(prefs,
                  "user_pref(\"network.proxy.socks_port\", #{proxy_port});\n")

  lib = '/usr/local/lib/tails-shell-library/chroot-browser.sh'
  $vm.execute_successfully("sed -i -E '/^\s*export TOR_TRANSPROXY=1/d' #{lib}")
end

Then /^I am told I cannot start the Unsafe Browser when I am offline$/ do
  assert_not_nil(
    Dogtail::Application.new('zenity')
    .child(roleName: 'label')
    .text['You are not connected to a local network']
  )
end

Then /^the Unsafe Browser complains that it is disabled$/ do
  assert_not_nil(
    Dogtail::Application.new('zenity')
    .child(roleName: 'label')
    .text['The Unsafe Browser was not enabled in the Welcome Screen']
  )
end

Then /^I configure the Unsafe Browser to check for updates more frequently$/ do
  prefs = '/usr/share/tails/chroot-browsers/unsafe-browser/prefs.js'
  $vm.file_append(prefs, 'pref("app.update.idletime", 1);')
  $vm.file_append(prefs, 'pref("app.update.promptWaitTime", 1);')
  $vm.file_append(prefs, 'pref("app.update.interval", 5);')
end

But /^checking for updates is disabled in the Unsafe Browser's configuration$/ do
  prefs = '/usr/share/tails/chroot-browsers/common/prefs.js'
  assert($vm.file_content(prefs).include?('pref("app.update.enabled", false)'))
end

Then /^the clearnet user has (|not )sent packets out to the Internet$/ do |sent|
  uid = $vm.execute_successfully('id -u clearnet').stdout.chomp.to_i
  pkts = ip4tables_packet_counter_sum(tables: ['OUTPUT'], uid: uid)
  case sent
  when ''
    assert(pkts.positive?, 'Packets have not gone out to the internet.')
  when 'not'
    assert_equal(0, pkts, 'Packets have gone out to the internet.')
  end
end
