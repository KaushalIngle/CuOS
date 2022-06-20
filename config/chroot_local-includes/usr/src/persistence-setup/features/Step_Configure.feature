Feature: configure step
  As a Tails user,
  in order to keep some persistent files,
  I want to configure Tails persistence feature.

  Scenario: build a Step::Configure object
    Given I have a Configuration object
    And I have a Step::Configure object
    Then I should have a defined Step::Configure object
    And the list of displayed settings should contain 13 elements
    And the list of configuration atoms should contain 14 elements
    And the list box should have 26 children including separators
    And there should be 2 active setting
    And there should be 1 setting with a configuration button
    And every active setting's atoms should be enabled
    And every inactive setting's atoms should be disabled

  Scenario: toggling an inactive setting on
    Given I have a Configuration object
    And I have a Step::Configure object
    When I toggle an inactive setting on
    Then there should be 3 active settings
    And every active setting's atoms should be enabled
    And every inactive setting's atoms should be disabled

  Scenario: toggling an active setting off
    Given I have a Configuration object
    And I have a Step::Configure object
    When I toggle an active setting off
    Then there should be 1 active setting
    And every active setting's atoms should be enabled
    And every inactive setting's atoms should be disabled

  Scenario: click save button
    Given I have a Configuration object
    And I have a Step::Configure object
    When I click the save button
    Then the file should contain 3 line

  Scenario: toggle on inactive setting that maps to 1 path and click save button
    Given I have a Configuration object
    And I have a Step::Configure object
    When I toggle the "Thunderbird" inactive setting on
    And I click the save button
    Then the file should contain 4 lines

  Scenario: toggle active setting off that maps to 2 paths and click save button
    Given I have a Configuration object
    And I have a Step::Configure object
    When I toggle the "AdditionalSoftware" active setting off
    And I click the save button
    Then the file should contain 1 lines

  Scenario: toggle active setting off and click save button
    Given I have a Configuration object
    And I have a Step::Configure object
    When I toggle the "PersonalData" active setting off
    And I click the save button
    Then the file should contain 2 line
