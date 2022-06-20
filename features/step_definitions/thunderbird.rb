def thunderbird_app
  Dogtail::Application.new('Thunderbird')
end

def thunderbird_main
  thunderbird_app.child(roleName: 'frame', recursive: false)
end

def thunderbird_wizard
  thunderbird_app.child('Account Setup - Mozilla Thunderbird', roleName: 'frame')
end

def thunderbird_inbox
  folder_view = thunderbird_main.child($config['Thunderbird']['address'],
                                       roleName: 'table row').parent
  folder_view.child(/^Inbox( .*)?$/, roleName: 'table row', recursive: false)
end

def enable_thunderbird_mozilla_cfg
  $vm.file_overwrite(
    '/usr/share/thunderbird/defaults/pref/autoconfig.js',
    <<~PREFS
      // This file must start with a comment or something
      pref("general.config.filename", "mozilla.cfg");
      pref("general.config.obscure_value", 0);
    PREFS
  )
end

def thunderbird_install_host_snakeoil_ssl_cert
  # Inspiration:
  # * https://wiki.mozilla.org/CA:AddRootToFirefox
  # * https://mike.kaply.com/2015/02/10/installing-certificates-into-firefox/
  debug_log('Installing host snakeoil SSL certificate')
  enable_thunderbird_mozilla_cfg
  cert = File.read('/etc/ssl/certs/ssl-cert-snakeoil.pem')
             .split("\n")
             .reject { |line| /^-----(BEGIN|END) CERTIFICATE-----$/.match(line) }
             .join
  $vm.file_overwrite(
    '/usr/lib/thunderbird/mozilla.cfg',
    <<~JS
      // This file must start with a comment or something
      var observer = {
        observe: function observe(aSubject, aTopic, aData) {
          var certdb = Components.classes["@mozilla.org/security/x509certdb;1"].getService(Components.interfaces.nsIX509CertDB);
          var certdb2 = certdb;
          try {
            certdb2 = Components.classes["@mozilla.org/security/x509certdb;1"].getService(Components.interfaces.nsIX509CertDB2);
          } catch (e) {}

          cert = "#{cert}";

          certdb2.addCertFromBase64(cert, "TCu,TCu,TCu", "");
        }
      }
      Components.utils.import("resource://gre/modules/Services.jsm");
      Services.obs.addObserver(observer, "profile-after-change", false);
    JS
  )
end

When /^I start Thunderbird$/ do
  workaround_pref_lines = [
    # When we generate a random subject line it may contain one of the
    # keywords that will make Thunderbird show an extra prompt when trying
    # to send an email. Let's disable this feature.
    'pref("mail.compose.attachment_reminder", false);',
  ]
  workaround_pref_lines.each do |line|
    $vm.file_append('/etc/thunderbird/pref/thunderbird.js', line + "\n")
  end
  # On Jenkins each isotester runs its own email server, using their
  # respecitve snakeoil SSL cert, so we have to import it.
  thunderbird_install_host_snakeoil_ssl_cert unless ENV['JENKINS_URL'].nil?
  step 'I start "ThunderbirdOverviewIcon.png" via GNOME Activities Overview'
  try_for(60) { thunderbird_main }
end

When /^I have not configured an email account yet$/ do
  conf_path = "/home/#{LIVE_USER}/.thunderbird/profile.default/prefs.js"
  if $vm.file_exist?(conf_path)
    thunderbird_prefs = $vm.file_content(conf_path).chomp
    assert(!thunderbird_prefs.include?('mail.accountmanager.accounts'))
  end
end

Then /^I am prompted to setup an email account$/ do
  thunderbird_wizard
end

Then /^I cancel setting up an email account$/ do
  thunderbird_wizard.button('Cancel').click
end

Then /^I open Thunderbird's Add-ons Manager$/ do
  # Make sure AppMenu is available, even if it seems hard to click its
  # "Add-ons" menu + menu item...
  thunderbird_main.button('AppMenu')
  # ... then use keyboard shortcuts, with a little delay between both
  # so that the menu has a chance to pop up:
  @screen.press('alt', 't')
  sleep(1)
  @screen.type('a')
  @thunderbird_addons = thunderbird_app.child(
    'Add-ons Manager', roleName: 'document web'
  )
end

Then /^I open the Extensions tab$/ do
  # Sometimes the Add-on manager loads its GUI slowly, so that the
  # tabs move around, creating a race where we might find the
  # Extensions tab at one place but it has moved to another when we
  # finally do the click.
  try_for(10) do
    @thunderbird_addons
      .child('Extensions', roleName: 'page tab', retry: false).click
    # Verify that we clicked correctly:
    @thunderbird_addons
      .child('Manage Your Extensions', roleName: 'heading', retry: false)
  end
end

Then /^I see that no add-ons are enabled in Thunderbird$/ do
  assert(!@thunderbird_addons.child?('Enabled', roleName: 'heading'))
end

When /^I enter my email credentials into the autoconfiguration wizard$/ do
  address = $config['Thunderbird']['address']
  name = address.split('@').first
  password = $config['Thunderbird']['password']
  thunderbird_wizard.child('Your full name', roleName: 'entry').typeText(name)
  thunderbird_wizard.child('Email address',
                           roleName: 'entry').typeText(address)
  thunderbird_wizard.child('Password', roleName: 'password text').typeText(password)
  thunderbird_wizard.button('Continue').click
  # This button is shown if and only if a configuration has been found
  try_for(120) { thunderbird_wizard.button('Done') }
end

Then /^the autoconfiguration wizard's choice for the (incoming|outgoing) server is secure (.+)$/ do |type, protocol|
  type = type.capitalize
  section = thunderbird_wizard.child(type, roleName: 'heading').parent
  subsections = section.children(roleName: 'section')
  assert(subsections.any? { |s| s.text == protocol })
  assert(subsections.any? { |s| s.text == 'SSL/TLS' || s.text == 'STARTTLS' })
end

def wait_for_thunderbird_progress_bar_to_vanish(thunderbird_frame)
  try_for(120) do
    thunderbird_frame.child(roleName: 'status bar', retry: false)
                     .child(roleName: 'progress bar', retry: false)
    false
  rescue StandardError
    true
  end
end

When /^I fetch my email$/ do
  account = thunderbird_main.child($config['Thunderbird']['address'],
                                   roleName: 'table row')
  account.click
  thunderbird_frame = thunderbird_app.child(
    "#{$config['Thunderbird']['address']} - Mozilla Thunderbird", roleName: 'frame'
  )

  thunderbird_frame.child('Mail Toolbar', roleName: 'tool bar')
                   .button('Get Messages').click
  wait_for_thunderbird_progress_bar_to_vanish(thunderbird_frame)
end

When /^I accept the (?:autoconfiguration wizard's|manual) configuration$/ do
  thunderbird_wizard.button('Done').click

  # The password check can fail due to bad Tor circuits.
  retry_tor do
    try_for(120) do
      # Spam the button, even if it is disabled (while it is still
      # testing the password).
      thunderbird_wizard.button('Finish').click
      false
    rescue StandardError
      true
    end
    true
  end

  # The account isn't fully created before we fetch our mail. For
  # instance, if we'd try to send an email before this, yet another
  # wizard will start, indicating (incorrectly) that we do not have an
  # account set up yet. Normally we disable automatic fetching of email,
  # and thus here we would immediately call "step 'I fetch my email'",
  # but Thunderbird 68 will fetch email immediately for a newly created
  # account despite our prefs (#17222), so here we first wait for this
  # operation to complete. But that initial fetch is incomplete,
  # e.g. only the INBOX folder is listed, so after that we fetch
  # email manually: otherwise Thunderbird does not know about the "Sent"
  # directory yet and sending email will fail when copying messages there.
  wait_for_thunderbird_progress_bar_to_vanish(thunderbird_main)
  step 'I fetch my email'
end

When /^I select the autoconfiguration wizard's IMAP choice$/ do
  thunderbird_wizard.child('IMAP (remote folders)', roleName: 'radio button').click
end

When /^I send an email to myself$/ do
  thunderbird_main.child('Mail Toolbar',
                         roleName: 'tool bar').button('Write').click
  compose_window = thunderbird_app.child('Write: (no subject) - Thunderbird')
  compose_window.child('To', roleName: 'entry')
                .typeText($config['Thunderbird']['address'])
  # The randomness of the subject will make it easier for us to later
  # find *exactly* this email. This makes it safe to run several tests
  # in parallel.
  @subject = "Automated test suite: #{random_alnum_string(32)}"
  compose_window.child('Subject', roleName: 'entry')
                .typeText(@subject)
  compose_window = thunderbird_app.child("Write: #{@subject} - Thunderbird")
  compose_window.child('Message body', roleName: 'document web')
                .typeText('test')
  compose_window.child('Composition Toolbar', roleName: 'tool bar')
                .button('Send').click
  try_for(120, delay: 2) do
    !compose_window.exist?
  end
end

Then /^I can find the email I sent to myself in my inbox$/ do
  recovery_proc = proc { step 'I fetch my email' }
  retry_tor(recovery_proc) do
    thunderbird_inbox.click
    filter = thunderbird_main.child('Filter these messages <Ctrl+Shift+K>',
                                    roleName: 'entry')
    filter.typeText(@subject)
    hit_counter = thunderbird_main.child('1 message')
    inbox_view = hit_counter.parent
    message_list = inbox_view.child(roleName: 'table')
    the_message = message_list.child(@subject, roleName: 'table cell')
    assert_not_nil(the_message)
    # Let's clean up
    the_message.click
    inbox_view.button('Delete').click
  end
end

Then /^my Thunderbird inbox is non-empty$/ do
  thunderbird_inbox.click
  message_list = thunderbird_main.child('Filter these messages <Ctrl+Shift+K>',
                                        roleName: 'entry')
                                 .parent.parent.child(roleName: 'table')
  visible_messages = message_list.children(recursive: false,
                                           roleName:  'table row')
  assert(!visible_messages.empty?)
end

Then(/^the screen keyboard works in Thunderbird$/) do
  step 'I start Thunderbird'
  osk_key = 'ScreenKeyboardKeyX.png'
  thunderbird_x = 'ThunderbirdX.png'
  case $language
  when 'Arabic'
    thunderbird_x = 'ThunderbirdXRTL.png'
  when 'Chinese'
    thunderbird_x = 'ThunderbirdXChinese.png'
  when 'Persian'
    osk_key = 'ScreenKeyboardKeyPersian.png'
    thunderbird_x = 'ThunderbirdXPersian.png'
  end
  @screen.wait('ScreenKeyboard.png', 10)
  @screen.wait(osk_key, 20).click
  @screen.wait(thunderbird_x, 20)
end
