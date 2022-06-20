@product
Feature: Browsing the web using the Tor Browser
  As a Tails user
  when I browse the web using the Tor Browser
  all Internet traffic should flow only through Tor

  Scenario: The Tor Browser cannot access the LAN
    Given I have started Tails from DVD and logged in and the network is connected
    And a web server is running on the LAN
    And I capture all network traffic
    When I start the Tor Browser
    And the Tor Browser loads the startup page
    And I open a page on the LAN web server in the Tor Browser
    Then the Tor Browser shows the "Unable to connect" error
    And no traffic was sent to the web server on the LAN

  @check_tor_leaks
  Scenario: The Tor Browser directory is usable
    Given I have started Tails from DVD and logged in and the network is connected
    Then the amnesiac Tor Browser directory exists
    And there is a GNOME bookmark for the amnesiac Tor Browser directory
    And the persistent Tor Browser directory does not exist
    When I start the Tor Browser
    And the Tor Browser loads the startup page
    Then I can save the current page as "index.html" to the default downloads directory
    And I can print the current page as "output.pdf" to the default downloads directory

  @check_tor_leaks
  Scenario: Downloading files with the Tor Browser
    Given I have started Tails from DVD and logged in and the network is connected
    When I start the Tor Browser
    Then the Tor Browser loads the startup page
    When I download some file in the Tor Browser
    Then I get the browser download dialog
    When I save the file to the default Tor Browser download directory
    Then the file is saved to the default Tor Browser download directory

  @check_tor_leaks
  Scenario: Playing an Ogg audio track
    Given I have started Tails from DVD and logged in and the network is connected
    When I start the Tor Browser
    And the Tor Browser loads the startup page
    Then I can listen to an Ogg audio track in Tor Browser

  @check_tor_leaks
  Scenario: Watching a WebM video
    Given I have started Tails from DVD and logged in and the network is connected
    When I start the Tor Browser
    And the Tor Browser loads the startup page
    Then I can watch a WebM video in Tor Browser

  Scenario: I can view a file stored in "~/Tor Browser" but not in ~/.gnupg
    Given I have started Tails from DVD and logged in and the network is connected
    And I copy "/usr/share/synaptic/html/index.html" to "/home/amnesia/Tor Browser/synaptic.html" as user "amnesia"
    And I copy "/usr/share/synaptic/html/index.html" to "/home/amnesia/.gnupg/synaptic.html" as user "amnesia"
    And I copy "/usr/share/synaptic/html/index.html" to "/tmp/synaptic.html" as user "amnesia"
    Then the file "/home/amnesia/.gnupg/synaptic.html" exists
    And the file "/lib/live/mount/overlay/rw/home/amnesia/.gnupg/synaptic.html" exists
    And the file "/live/overlay/rw/home/amnesia/.gnupg/synaptic.html" exists
    And the file "/tmp/synaptic.html" exists
    Given I start monitoring the AppArmor log of "torbrowser_firefox"
    When I start the Tor Browser
    And the Tor Browser loads the startup page
    And I open the address "file:///home/amnesia/Tor Browser/synaptic.html" in the Tor Browser
    Then I see "TorBrowserSynapticManual.png" after at most 5 seconds
    And AppArmor has not denied "torbrowser_firefox" from opening "/home/amnesia/Tor Browser/synaptic.html"
    Given I restart monitoring the AppArmor log of "torbrowser_firefox"
    When I open the address "file:///home/amnesia/.gnupg/synaptic.html" in the Tor Browser
    Then I do not see "TorBrowserSynapticManual.png" after at most 5 seconds
    And AppArmor has denied "torbrowser_firefox" from opening "/home/amnesia/.gnupg/synaptic.html"
    Given I restart monitoring the AppArmor log of "torbrowser_firefox"
    When I open the address "file:///lib/live/mount/overlay/rw/home/amnesia/.gnupg/synaptic.html" in the Tor Browser
    Then I do not see "TorBrowserSynapticManual.png" after at most 5 seconds
    And AppArmor has denied "torbrowser_firefox" from opening "/lib/live/mount/overlay/rw/home/amnesia/.gnupg/synaptic.html"
    Given I restart monitoring the AppArmor log of "torbrowser_firefox"
    When I open the address "file:///live/overlay/rw/home/amnesia/.gnupg/synaptic.html" in the Tor Browser
    Then I do not see "TorBrowserSynapticManual.png" after at most 5 seconds
    # Due to our AppArmor aliases, /live/overlay will be treated
    # as /lib/live/mount/overlay.
    And AppArmor has denied "torbrowser_firefox" from opening "/lib/live/mount/overlay/rw/home/amnesia/.gnupg/synaptic.html"
    # We do not get any AppArmor log for when access to files in /tmp is denied
    # since we explictly override (commit 51c0060) the rules (from the user-tmp
    # abstraction) that would otherwise allow it, and we do so with "deny", which
    # also specifies "noaudit". We could explicitly specify "audit deny" and
    # then have logs, but it could be a problem when we set up desktop
    # notifications for AppArmor denials (#9337).
    When I open the address "file:///tmp/synaptic.html" in the Tor Browser
    Then I do not see "TorBrowserSynapticManual.png" after at most 5 seconds

  Scenario: The Tor Browser uses TBB's shared libraries
    Given I have started Tails from DVD and logged in and the network is connected
    When I start the Tor Browser
    Then the Tor Browser uses all expected TBB shared libraries

  @check_tor_leaks
  Scenario: The Tor Browser's "New identity" feature works as expected
    Given I have started Tails from DVD and logged in and the network is connected
    When I start the Tor Browser
    And the Tor Browser loads the startup page
    And I open the Tails homepage in the Tor Browser
    Then the Tor Browser loads the Tails homepage
    When I request a new identity using Torbutton
    And I acknowledge Torbutton's New Identity confirmation prompt
    Then the Tor Browser loads the startup page

  Scenario: WebRTC is disabled in Tor Browser
    Given I have started Tails from DVD and logged in and the network is connected
    When I start the Tor Browser
    And the Tor Browser loads the startup page
    When I open the address "https://net.ipcalf.com/" in the Tor Browser
    Then Tor Browser displays a 'ifconfig | grep inet | grep -v inet6 | cut -d" " -f2 | tail -n1' heading on the "Network IP Address via ipcalf.com" page
    When I open the address "https://mozilla.github.io/webrtc-landing/pc_test.html" in the Tor Browser
    Then Tor Browser displays a "RTCPeerConnection is missing!" heading on the "Simple RTCPeerConnection Video Test" page

  #15336
  @fragile
  Scenario: The persistent Tor Browser directory is usable
    Given I have started Tails without network from a USB drive with a persistent partition enabled and logged in
    And the network is plugged
    And Tor is ready
    And available upgrades have been checked
    And all notifications have disappeared
    Then the persistent Tor Browser directory exists
    And there is a GNOME bookmark for the persistent Tor Browser directory
    When I start the Tor Browser
    And I open the address "https://tails.boum.org/about" in the Tor Browser
    And "Tails - How Tails works" has loaded in the Tor Browser
    Then I can save the current page as "index.html" to the persistent Tor Browser directory
    And I open the address "file:///home/amnesia/Persistent/Tor Browser/index.html" in the Tor Browser
    Then "Tails - How Tails works" has loaded in the Tor Browser
    And I can print the current page as "output.pdf" to the persistent Tor Browser directory

  #11585
  @fragile
  Scenario: Persistent browser bookmarks
    Given I have started Tails without network from a USB drive with a persistent partition enabled and logged in
    And all persistence presets are enabled
    And all persistent filesystems have safe access rights
    And all persistence configuration files have safe access rights
    And all persistent directories have safe access rights
    When I start the Tor Browser in offline mode
    And I add a bookmark to eff.org in the Tor Browser
    And I cold reboot the computer
    And the computer reboots Tails
    And I enable persistence
    And I log in to a new session
    And I start the Tor Browser in offline mode
    Then the Tor Browser has a bookmark to eff.org
