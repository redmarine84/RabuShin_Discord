import { DiscordSDK } from '@discord/embedded-app-sdk';
import './style.css';


// ========================================================
// DISCORD SDK
// ========================================================

const discordSdk =
    new DiscordSDK(
        import.meta.env.VITE_DISCORD_CLIENT_ID
    );

let discordAuth = null;

let currentDiscordUser = null;

let discordAccessToken = null;


// ========================================================
// STARTING SCREEN
// ========================================================

document.querySelector('#app').innerHTML = `

  <div class="rabushin-app">

    <header class="game-header">

      <div>

        <h1>
          RabuShin AI Game Master
        </h1>

        <div class="subtitle">
          The Quests of Rabu Shin
        </div>

      </div>


      <div class="header-right">

        <div
          id="discordUser"
          class="discord-user"
        >

          Connecting to Discord...

        </div>


        <div
          id="serverStatus"
          class="server-status"
        >

          Checking Server...

        </div>

      </div>

    </header>


    <main
      id="mainContent"
      class="game-content"
    >

      <section class="panel loading-panel">

        <h2>
          Loading RabuShin
        </h2>

        <p>
          Connecting your Discord account...
        </p>

      </section>

    </main>

  </div>

`;


// ========================================================
// DISCORD AUTHENTICATION
// ========================================================

async function setupDiscord() {

    const userBox =
        document.querySelector(
            '#discordUser'
        );


    function showStatus(message) {

        userBox.innerHTML = `

      <div class="discord-user-label">
        Discord Login
      </div>

      <div class="discord-user-name">
        ${escapeHtml(message)}
      </div>

    `;

    }


    function withTimeout(
        promise,
        seconds,
        stepName
    ) {

        return Promise.race([

            promise,

            new Promise(
                (_, reject) => {

                    setTimeout(
                        () => {

                            reject(
                                new Error(
                                    `${stepName} timed out after ${seconds} seconds.`
                                )
                            );

                        },

                        seconds * 1000

                    );

                }
            )

        ]);

    }


    try {

        const clientId =
            import.meta.env
                .VITE_DISCORD_CLIENT_ID;


        if (!clientId) {

            throw new Error(
                'VITE_DISCORD_CLIENT_ID was not loaded.'
            );

        }


        showStatus(
            'Connecting...'
        );


        await withTimeout(
            discordSdk.ready(),
            10,
            'Discord SDK'
        );


        const authorizeResult =
            await withTimeout(

                discordSdk.commands.authorize({

                    client_id:
                        clientId,

                    response_type:
                        'code',

                    state:
                        '',

                    prompt:
                        'none',

                    scope: [
                        'identify'
                    ]

                }),

                20,

                'Discord authorization'

            );


        if (!authorizeResult?.code) {

            throw new Error(
                'Discord returned no authorization code.'
            );

        }


        const tokenResponse =
            await fetch(
                '/api/token',
                {

                    method:
                        'POST',

                    headers: {

                        'Content-Type':
                            'application/json'

                    },

                    body:
                        JSON.stringify({

                            code:
                                authorizeResult.code

                        })

                }
            );


        if (!tokenResponse.ok) {

            const text =
                await tokenResponse.text();

            throw new Error(
                `Token exchange failed: ${text}`
            );

        }


        const tokenData =
            await tokenResponse.json();


        if (!tokenData.access_token) {

            throw new Error(
                'Discord token server returned no access token.'
            );

        }

        discordAccessToken =
            tokenData.access_token;


        discordAuth =
            await discordSdk.commands
                .authenticate({

                    access_token:
                        tokenData.access_token

                });


        if (!discordAuth?.user) {

            throw new Error(
                'Discord returned no user.'
            );

        }


        currentDiscordUser =
            discordAuth.user;


        const displayName =
            currentDiscordUser.global_name ||
            currentDiscordUser.username;


        userBox.innerHTML = `

      <div class="discord-user-label">
        Playing As
      </div>

      <div class="discord-user-name">
        ${escapeHtml(displayName)}
      </div>

      <div class="discord-user-username">
        @${escapeHtml(
            currentDiscordUser.username
        )}
      </div>

    `;


        userBox.classList.add(
            'connected'
        );


        // Discord login succeeded.
        // Now show the real game launcher.

        showCampaignLauncher();

    }
    catch (error) {

        console.error(
            'Discord authentication failed:',
            error
        );


        userBox.innerHTML = `

      <div class="discord-user-label">
        Discord Authentication Error
      </div>

      <div class="discord-user-error">
        ${escapeHtml(
            error.message
        )}
      </div>

    `;


        showFatalError(
            'Discord authentication failed.'
        );

    }

}


// ========================================================
// CAMPAIGN LAUNCHER
// ========================================================

function showCampaignLauncher() {

    const main =
        document.querySelector(
            '#mainContent'
        );


    const displayName =
        currentDiscordUser?.global_name ||
        currentDiscordUser?.username ||
        'Player';


    main.innerHTML = `

    <div class="launcher-container">


      <!-- =========================================== -->
      <!-- WELCOME                                     -->
      <!-- =========================================== -->

      <section class="launcher-welcome">

        <div>

          <h2>
            Welcome, ${escapeHtml(displayName)}
          </h2>

          <p>
            Choose a campaign to continue your adventure,
            start a new campaign, or join another player's
            campaign.
          </p>

        </div>

      </section>


      <!-- =========================================== -->
      <!-- MY CAMPAIGNS                                -->
      <!-- =========================================== -->

      <section class="campaign-panel">

        <div class="panel-heading">

          <div>

            <h3>
              My Campaigns
            </h3>

            <p>
              Campaigns you own or have joined.
            </p>

          </div>


          <button
            id="refreshCampaigns"
            class="small-button"
          >
            Refresh
          </button>

        </div>


        <div
          id="campaignList"
          class="campaign-list"
        >

          <div class="empty-campaigns">

            <div class="empty-icon">
              ⚔
            </div>

            <div class="empty-title">
              No campaigns loaded yet
            </div>

            <div class="empty-description">

              The launcher is ready.
              Supabase campaign synchronization
              will be connected next.

            </div>

          </div>

        </div>

      </section>


      <!-- =========================================== -->
      <!-- ACTIONS                                     -->
      <!-- =========================================== -->

      <section class="launcher-actions">

        <button
          id="newCampaignButton"
          class="launcher-action primary-action"
        >

          <span class="action-icon">
            +
          </span>

          <span>

            <strong>
              Start New Campaign
            </strong>

            <small>
              Create a new multiplayer adventure
            </small>

          </span>

        </button>


        <button
          id="joinCampaignButton"
          class="launcher-action"
        >

          <span class="action-icon">
            #
          </span>

          <span>

            <strong>
              Join With Campaign Code
            </strong>

            <small>
              Enter a code from another player
            </small>

          </span>

        </button>

      </section>


      <!-- =========================================== -->
      <!-- PLAYER INFORMATION                          -->
      <!-- =========================================== -->

      <section class="player-info-panel">

        <div>

          <span class="info-label">
            Discord Player
          </span>

          <span>
            ${escapeHtml(
        currentDiscordUser.username
    )}
          </span>

        </div>


        <div>

          <span class="info-label">
            Discord User ID
          </span>

          <span class="discord-id">
            ${escapeHtml(
        currentDiscordUser.id
    )}
          </span>

        </div>

      </section>


      <!-- =========================================== -->
      <!-- DEVELOPMENT TOOLS                           -->
      <!-- =========================================== -->

      <details
        class="developer-tools"
      >

        <summary>
          Development Tools
        </summary>


        <div class="developer-content">

          <button
            id="testDiceButton"
            class="small-button"
          >
            Test VB.NET D20
          </button>


          <div
            id="developerResult"
          >
          </div>

        </div>

      </details>


    </div>

  `;


    // ---------------------------------------------------
    // EVENT HANDLERS
    // ---------------------------------------------------

    document
        .querySelector(
            '#refreshCampaigns'
        )
        .addEventListener(
            'click',
            loadCampaigns
        );


    document
        .querySelector(
            '#newCampaignButton'
        )
        .addEventListener(
            'click',
            showNewCampaignDialog
        );


    document
        .querySelector(
            '#joinCampaignButton'
        )
        .addEventListener(
            'click',
            showJoinCampaignDialog
        );


    document
        .querySelector(
            '#testDiceButton'
        )
        .addEventListener(
            'click',
            testDice
        );


    loadCampaigns();

}


// ========================================================
// LOAD CAMPAIGNS
// ========================================================

async function loadCampaigns() {

    const list =
        document.querySelector(
            '#campaignList'
        );


    if (!list) {
        return;
    }


    list.innerHTML = `

    <div class="campaign-loading">
      Loading campaigns...
    </div>

  `;


    try {

        const response =
            await fetch(
                '/game-api/campaigns',
                {

                    headers: {

                        'Authorization':
                            `Bearer ${discordAccessToken}`

                    }

                }
            );


        const data =
            await response.json();


        if (!response.ok || !data.success) {

            throw new Error(
                data.error ||
                'Unable to load campaigns.'
            );

        }


        renderCampaigns(
            data.campaigns
        );

    }
    catch (error) {

        console.error(error);


        list.innerHTML = `

      <div class="empty-campaigns">

        <div class="empty-title">
          Unable to load campaigns
        </div>

        <div class="empty-description">
          ${escapeHtml(error.message)}
        </div>

      </div>

    `;

    }

}

function renderCampaigns(
    campaigns
) {

    const list =
        document.querySelector(
            '#campaignList'
        );


    if (
        !campaigns ||
        campaigns.length === 0
    ) {

        list.innerHTML = `

      <div class="empty-campaigns">

        <div class="empty-icon">
          ⚔
        </div>

        <div class="empty-title">
          No campaigns yet
        </div>

        <div class="empty-description">

          Start a new campaign or join one
          using a campaign code.

        </div>

      </div>

    `;


        return;

    }


    list.innerHTML =
        campaigns.map(
            campaign => `

        <div class="campaign-card">

          <div class="campaign-main">

            <div class="campaign-name">

              ${escapeHtml(
                campaign.campaignName
            )}

            </div>


            <div class="campaign-details">

              Chapter
              ${campaign.currentChapter}

              &nbsp;•&nbsp;

              ${escapeHtml(
                campaign.currentLocation
            )}

              &nbsp;•&nbsp;

              ${campaign.memberCount}
              Player${campaign.memberCount === 1 ? '' : 's'}

            </div>


            <div class="campaign-code">

              Campaign Code:

              <strong>
                ${escapeHtml(
                campaign.joinCode
            )}
              </strong>

            </div>

          </div>


          <div class="campaign-card-actions">

            ${campaign.isOwner
                    ?
                    `
                  <span class="owner-badge">
                    OWNER
                  </span>
                `
                    :
                    ''
                }


            <button
              class="small-button play-campaign"
              data-campaign-id="${campaign.campaignId}"
            >
              Play
            </button>

          </div>

        </div>

      `
        )
            .join('');


    document
        .querySelectorAll(
            '.play-campaign'
        )
        .forEach(
            button => {

                button.addEventListener(
                    'click',
                    () => {

                        openCampaign(
                            button.dataset.campaignId
                        );

                    }
                );

            }
        );

}

async function openCampaign(
    campaignId
) {

    showNotice(
        'Checking character...'
    );


    try {

        const response =
            await fetch(
                `/game-api/campaigns/${campaignId}/character`,
                {

                    headers: {

                        'Authorization':
                            `Bearer ${discordAccessToken}`

                    }

                }
            );


        const data =
            await response.json();


        if (
            !response.ok ||
            !data.success
        ) {

            throw new Error(
                data.error ||
                'Unable to check character.'
            );

        }


        if (data.hasCharacter) {

            await continueCharacterSetup(
                campaignId,
                data.character
            );

        }
        else {

            await showCharacterCreator(
                campaignId
            );

        }

    }
    catch (error) {

        console.error(error);

        showNotice(
            error.message
        );

    }

}

async function continueCharacterSetup(
    campaignId,
    character
) {

    try {

        const response =
            await fetch(
                `/game-api/campaigns/${campaignId}/character/setup`,
                {

                    headers: {

                        'Authorization':
                            `Bearer ${discordAccessToken}`

                    }

                }
            );


        const data =
            await response.json();


        if (
            !response.ok ||
            !data.success
        ) {

            throw new Error(
                data.error ||
                'Unable to determine character setup.'
            );

        }


        if (!data.equipmentComplete) {

            await showStartingEquipment(
                campaignId,
                character
            );

            return;

        }


        showCharacterReady(
            campaignId,
            character
        );

    }
    catch (error) {

        console.error(error);

        showNotice(
            error.message
        );

    }

}

async function showCharacterCreator(
    campaignId
) {

    const main =
        document.querySelector(
            '#mainContent'
        );


    main.innerHTML = `

    <div class="character-creator">

      <div class="creator-header">

        <div>

          <h2>
            Create Your Character
          </h2>

          <p>
            Each player may create one
            character for this campaign.
          </p>

        </div>


        <button
          id="backToCampaigns"
          class="small-button"
        >
          Back
        </button>

      </div>


      <div class="creator-mode-tabs">

        <button
          id="randomModeButton"
          class="creator-mode-button active"
        >
          Random Build
        </button>


        <button
          id="manualModeButton"
          class="creator-mode-button"
        >
          Manual Sheet
        </button>

      </div>


      <section class="creator-panel">


        <!-- =========================================== -->
        <!-- RANDOM BUILD                                -->
        <!-- =========================================== -->

        <div id="randomCreator">

          <div class="creator-mode-title">
            Random Build
          </div>


          <p class="creator-description">

            Choose a species and class.
            RabuShin generates the remaining
            character using your existing
            VB.NET character rules.

          </p>


          <label class="form-label">
            Character Name
          </label>

          <input
            id="newCharacterName"
            class="game-input"
            type="text"
            maxlength="80"
            placeholder="Leave blank for a generated name"
            autocomplete="off"
          />


          <label
            class="form-label creator-field"
          >
            Species / Race
          </label>

          <select
            id="newCharacterSpecies"
            class="game-input"
          >
          </select>


          <label
            class="form-label creator-field"
          >
            Class
          </label>

          <select
            id="newCharacterClass"
            class="game-input"
          >
          </select>


          <div class="creator-help">

            Half species automatically receive
            a randomly selected second heritage.

          </div>


          <button
            id="generateCharacter"
            class="creator-generate-button"
          >
            Generate Character
          </button>

        </div>


        <!-- =========================================== -->
        <!-- MANUAL SHEET                                -->
        <!-- =========================================== -->

        <div
          id="manualCreator"
          style="display:none;"
        >

          <div class="creator-mode-title">
            Manual Sheet
          </div>


          <p class="creator-description">

            Choose your identity and ability scores.
            Heritage bonuses and derived combat
            statistics are calculated by the
            RabuShin VB.NET game engine.

          </p>


          <div class="manual-section-title">
            Identity
          </div>


          <div class="manual-form-grid">

            <div>

              <label class="form-label">
                Character Name
              </label>

              <input
                id="manualName"
                class="game-input"
                type="text"
                maxlength="80"
                autocomplete="off"
              />

            </div>


            <div>

              <label class="form-label">
                Level
              </label>

              <input
                id="manualLevel"
                class="game-input"
                type="number"
                min="1"
                max="20"
                value="1"
              />

            </div>


            <div>

              <label class="form-label">
                Species / Race
              </label>

              <select
                id="manualSpecies"
                class="game-input"
              >
              </select>

            </div>


            <div
              id="secondaryHeritageContainer"
              style="display:none;"
            >

              <label class="form-label">
                Other Half
              </label>

              <select
                id="manualSecondaryHeritage"
                class="game-input"
              >
              </select>

            </div>


            <div>

              <label class="form-label">
                Class
              </label>

              <select
                id="manualClass"
                class="game-input"
              >
              </select>

            </div>


            <div>

              <label class="form-label">
                Background
              </label>

              <select
                id="manualBackground"
                class="game-input"
              >
              </select>

            </div>


            <div>

              <label class="form-label">
                Alignment
              </label>

              <select
                id="manualAlignment"
                class="game-input"
              >
              </select>

            </div>

          </div>


          <div class="manual-section-title">
            Ability Scores
          </div>


          <div class="manual-ability-help">

            Enter each base score from 1–20.
            Racial/heritage bonuses are applied
            afterward and still cannot raise
            an ability above 20.

          </div>


          <div class="manual-ability-grid">

            ${manualAbilityInput(
        'STR',
        'manualStrength'
    )}

            ${manualAbilityInput(
        'DEX',
        'manualDexterity'
    )}

            ${manualAbilityInput(
        'CON',
        'manualConstitution'
    )}

            ${manualAbilityInput(
        'INT',
        'manualIntelligence'
    )}

            ${manualAbilityInput(
        'WIS',
        'manualWisdom'
    )}

            ${manualAbilityInput(
        'CHA',
        'manualCharisma'
    )}

          </div>


          <div class="manual-section-title">
            Character Details
          </div>


          <label class="form-label">
            Appearance
          </label>

          <textarea
            id="manualAppearance"
            class="game-input manual-textarea"
            placeholder="Optional"
          ></textarea>


          <label
            class="form-label creator-field"
          >
            Personality
          </label>

          <textarea
            id="manualPersonality"
            class="game-input manual-textarea"
            placeholder="Optional"
          ></textarea>


          <label
            class="form-label creator-field"
          >
            Backstory
          </label>

          <textarea
            id="manualBackstory"
            class="game-input manual-textarea"
            placeholder="Optional"
          ></textarea>


          <label
            class="form-label creator-field"
          >
            Notes
          </label>

          <textarea
            id="manualNotes"
            class="game-input manual-textarea"
            placeholder="Optional"
          ></textarea>


          <button
            id="createManualCharacter"
            class="creator-generate-button"
          >
            Create Character
          </button>

        </div>


        <div
          id="creatorLoading"
          class="campaign-loading"
        >
          Loading character options...
        </div>


        <div
          id="creatorError"
          class="creator-error"
        >
        </div>

      </section>

    </div>

  `;


    document
        .querySelector(
            '#backToCampaigns'
        )
        .addEventListener(
            'click',
            showCampaignLauncher
        );


    try {

        const response =
            await fetch(
                '/game-api/character-options'
            );


        const data =
            await response.json();


        if (
            !response.ok ||
            !data.success
        ) {

            throw new Error(
                data.error ||
                'Unable to load character options.'
            );

        }


        // ==================================================
        // RANDOM BUILD OPTIONS
        // ==================================================

        populateSelect(
            '#newCharacterSpecies',
            data.species
        );


        populateSelect(
            '#newCharacterClass',
            data.classes
        );


        document
            .querySelector(
                '#newCharacterSpecies'
            )
            .value =
            'Human';


        document
            .querySelector(
                '#newCharacterClass'
            )
            .value =
            'Fighter';


        // ==================================================
        // MANUAL OPTIONS
        // ==================================================

        populateSelect(
            '#manualSpecies',
            data.species
        );


        populateSelect(
            '#manualClass',
            data.classes
        );


        populateSelect(
            '#manualBackground',
            data.backgrounds
        );


        populateSelect(
            '#manualAlignment',
            data.alignments
        );


        const manualSpecies =
            document.querySelector(
                '#manualSpecies'
            );


        manualSpecies.value =
            'Human';


        document
            .querySelector(
                '#manualClass'
            )
            .value =
            'Fighter';


        document
            .querySelector(
                '#manualBackground'
            )
            .value =
            'Soldier';


        document
            .querySelector(
                '#manualAlignment'
            )
            .value =
            'Neutral';


        // ==================================================
        // HALF HERITAGE
        // ==================================================

        function updateSecondaryHeritage() {

            const selected =
                manualSpecies.value;


            const container =
                document.querySelector(
                    '#secondaryHeritageContainer'
                );


            const secondary =
                document.querySelector(
                    '#manualSecondaryHeritage'
                );


            if (
                selected.startsWith(
                    'Half '
                )
            ) {

                const primary =
                    selected.substring(5);


                const choices =
                    data.baseSpecies.filter(
                        species =>
                            species.toLowerCase() !==
                            primary.toLowerCase()
                    );


                secondary.innerHTML =
                    choices
                        .map(
                            item => `

                <option
                  value="${escapeHtml(item)}"
                >
                  ${escapeHtml(item)}
                </option>

              `
                        )
                        .join('');


                container.style.display =
                    'block';

            }
            else {

                container.style.display =
                    'none';


                secondary.innerHTML =
                    '';

            }

        }


        manualSpecies.addEventListener(
            'change',
            updateSecondaryHeritage
        );


        updateSecondaryHeritage();


        // ==================================================
        // MODE BUTTONS
        // ==================================================

        const randomButton =
            document.querySelector(
                '#randomModeButton'
            );


        const manualButton =
            document.querySelector(
                '#manualModeButton'
            );


        const randomCreator =
            document.querySelector(
                '#randomCreator'
            );


        const manualCreator =
            document.querySelector(
                '#manualCreator'
            );


        randomButton.addEventListener(
            'click',
            () => {

                randomButton.classList.add(
                    'active'
                );


                manualButton.classList.remove(
                    'active'
                );


                randomCreator.style.display =
                    'block';


                manualCreator.style.display =
                    'none';

            }
        );


        manualButton.addEventListener(
            'click',
            () => {

                manualButton.classList.add(
                    'active'
                );


                randomButton.classList.remove(
                    'active'
                );


                randomCreator.style.display =
                    'none';


                manualCreator.style.display =
                    'block';

            }
        );


        // ==================================================
        // CREATE BUTTONS
        // ==================================================

        document
            .querySelector(
                '#generateCharacter'
            )
            .addEventListener(
                'click',
                () => {

                    createRandomCharacter(
                        campaignId
                    );

                }
            );


        document
            .querySelector(
                '#createManualCharacter'
            )
            .addEventListener(
                'click',
                () => {

                    createManualCharacter(
                        campaignId
                    );

                }
            );


        document
            .querySelector(
                '#creatorLoading'
            )
            .style.display =
            'none';

    }
    catch (error) {

        document
            .querySelector(
                '#creatorLoading'
            )
            .textContent =
            'Unable to load character creator.';


        document
            .querySelector(
                '#creatorError'
            )
            .textContent =
            error.message;

    }

}

function populateSelect(
    selector,
    values
) {

    const select =
        document.querySelector(
            selector
        );


    select.innerHTML =
        values
            .map(
                item => `

          <option
            value="${escapeHtml(item)}"
          >
            ${escapeHtml(item)}
          </option>

        `
            )
            .join('');

}


function manualAbilityInput(
    label,
    id
) {

    return `

    <div class="manual-ability">

      <label>
        ${label}
      </label>

      <input
        id="${id}"
        type="number"
        min="1"
        max="20"
        value="10"
      />

    </div>

  `;

}

async function createManualCharacter(
    campaignId
) {

    const button =
        document.querySelector(
            '#createManualCharacter'
        );


    const errorBox =
        document.querySelector(
            '#creatorError'
        );


    errorBox.textContent =
        '';


    const species =
        document
            .querySelector(
                '#manualSpecies'
            )
            .value;


    const isHalf =
        species.startsWith(
            'Half '
        );


    const secondaryHeritage =
        isHalf
            ?
            document
                .querySelector(
                    '#manualSecondaryHeritage'
                )
                .value
            :
            '';


    const request = {

        characterName:
            document
                .querySelector(
                    '#manualName'
                )
                .value
                .trim(),

        species:
            species,

        secondaryHeritage:
            secondaryHeritage,

        className:
            document
                .querySelector(
                    '#manualClass'
                )
                .value,

        background:
            document
                .querySelector(
                    '#manualBackground'
                )
                .value,

        alignment:
            document
                .querySelector(
                    '#manualAlignment'
                )
                .value,

        level:
            Number(
                document
                    .querySelector(
                        '#manualLevel'
                    )
                    .value
            ),

        strength:
            getManualAbility(
                '#manualStrength'
            ),

        dexterity:
            getManualAbility(
                '#manualDexterity'
            ),

        constitution:
            getManualAbility(
                '#manualConstitution'
            ),

        intelligence:
            getManualAbility(
                '#manualIntelligence'
            ),

        wisdom:
            getManualAbility(
                '#manualWisdom'
            ),

        charisma:
            getManualAbility(
                '#manualCharisma'
            ),

        appearance:
            document
                .querySelector(
                    '#manualAppearance'
                )
                .value
                .trim(),

        personality:
            document
                .querySelector(
                    '#manualPersonality'
                )
                .value
                .trim(),

        backstory:
            document
                .querySelector(
                    '#manualBackstory'
                )
                .value
                .trim(),

        notes:
            document
                .querySelector(
                    '#manualNotes'
                )
                .value
                .trim()

    };


    if (!request.characterName) {

        errorBox.textContent =
            'Character name is required.';

        return;

    }


    button.disabled =
        true;


    button.textContent =
        'Creating Character...';


    try {

        const response =
            await fetch(
                `/game-api/campaigns/${campaignId}/characters/manual`,
                {

                    method:
                        'POST',

                    headers: {

                        'Content-Type':
                            'application/json',

                        'Authorization':
                            `Bearer ${discordAccessToken}`

                    },

                    body:
                        JSON.stringify(
                            request
                        )

                }
            );


        const data =
            await response.json();


        if (
            !response.ok ||
            !data.success
        ) {

            throw new Error(
                data.error ||
                'Character creation failed.'
            );

        }


        await showStartingEquipment(
            campaignId,
            data.character
        );

    }
    catch (error) {

        console.error(error);


        errorBox.textContent =
            error.message;


        button.disabled =
            false;


        button.textContent =
            'Create Character';

    }

}

async function showStartingEquipment(
    campaignId,
    character
) {

    const main =
        document.querySelector(
            '#mainContent'
        );


    main.innerHTML = `

    <div class="starting-equipment">

      <div class="creator-header">

        <div>

          <h2>
            Starting Equipment
          </h2>

          <p>

            ${escapeHtml(
        character.characterName
    )}

            •

            ${escapeHtml(
        character.className
    )}

          </p>

        </div>

      </div>


      <section class="creator-panel">

        <div
          id="equipmentLoading"
          class="campaign-loading"
        >
          Loading starting equipment...
        </div>


        <div
          id="equipmentForm"
          style="display:none;"
        >

          <div class="equipment-section">

            <div class="manual-section-title">
              Class Equipment
            </div>


            <label class="form-label">
              Package
            </label>


            <select
              id="classEquipmentPackage"
              class="game-input"
            >
            </select>


            <div
              id="classChoiceContainer"
              class="equipment-choice"
              style="display:none;"
            >

              <label class="form-label">
                Choose Item
              </label>


              <select
                id="classEquipmentChoice"
                class="game-input"
              >
              </select>

            </div>

          </div>


          <div class="equipment-section">

            <div class="manual-section-title">
              Background Equipment
            </div>


            <label class="form-label">
              Package
            </label>


            <select
              id="backgroundEquipmentPackage"
              class="game-input"
            >
            </select>


            <div
              id="backgroundChoiceContainer"
              class="equipment-choice"
              style="display:none;"
            >

              <label class="form-label">
                Choose Item
              </label>


              <select
                id="backgroundEquipmentChoice"
                class="game-input"
              >
              </select>

            </div>

          </div>


          <div class="manual-section-title">
            Starting Inventory Preview
          </div>


          <div
            id="equipmentPreview"
            class="equipment-preview"
          >
          </div>


          <div class="starting-gold">

            Starting Gold:

            <strong id="startingGold">
              0 GP
            </strong>

          </div>


          <div
            id="equipmentError"
            class="creator-error"
          >
          </div>


          <button
            id="saveStartingEquipment"
            class="creator-generate-button"
          >
            Accept Starting Equipment
          </button>

        </div>

      </section>

    </div>

  `;


    try {

        const response =
            await fetch(
                `/game-api/campaigns/${campaignId}/starting-equipment`,
                {

                    headers: {

                        'Authorization':
                            `Bearer ${discordAccessToken}`

                    }

                }
            );


        const data =
            await response.json();


        if (
            !response.ok ||
            !data.success
        ) {

            throw new Error(
                data.error ||
                'Unable to load starting equipment.'
            );

        }


        const classSelect =
            document.querySelector(
                '#classEquipmentPackage'
            );


        const backgroundSelect =
            document.querySelector(
                '#backgroundEquipmentPackage'
            );


        classSelect.innerHTML =
            data.classPackages
                .map(
                    packageInfo => `

            <option
              value="${packageInfo.index}"
            >
              ${escapeHtml(
                        packageInfo.label
                    )}
            </option>

          `
                )
                .join('');


        backgroundSelect.innerHTML =
            data.backgroundPackages
                .map(
                    packageInfo => `

            <option
              value="${packageInfo.index}"
            >
              ${escapeHtml(
                        packageInfo.label
                    )}
            </option>

          `
                )
                .join('');


        function currentClassPackage() {

            return data.classPackages[
                Number(
                    classSelect.value
                )
            ];

        }


        function currentBackgroundPackage() {

            return data.backgroundPackages[
                Number(
                    backgroundSelect.value
                )
            ];

        }


        function updateChoices() {

            configureEquipmentChoice(

                currentClassPackage(),

                '#classChoiceContainer',

                '#classEquipmentChoice'

            );


            configureEquipmentChoice(

                currentBackgroundPackage(),

                '#backgroundChoiceContainer',

                '#backgroundEquipmentChoice'

            );


            updateEquipmentPreview(

                currentClassPackage(),

                currentBackgroundPackage()

            );

        }


        classSelect.addEventListener(
            'change',
            updateChoices
        );


        backgroundSelect.addEventListener(
            'change',
            updateChoices
        );


        document
            .querySelector(
                '#classEquipmentChoice'
            )
            .addEventListener(
                'change',
                () => {

                    updateEquipmentPreview(

                        currentClassPackage(),

                        currentBackgroundPackage()

                    );

                }
            );


        document
            .querySelector(
                '#backgroundEquipmentChoice'
            )
            .addEventListener(
                'change',
                () => {

                    updateEquipmentPreview(

                        currentClassPackage(),

                        currentBackgroundPackage()

                    );

                }
            );


        document
            .querySelector(
                '#saveStartingEquipment'
            )
            .addEventListener(
                'click',
                async () => {

                    await saveStartingEquipment(

                        campaignId,

                        currentClassPackage(),

                        currentBackgroundPackage()

                    );

                }
            );


        document
            .querySelector(
                '#equipmentLoading'
            )
            .style.display =
            'none';


        document
            .querySelector(
                '#equipmentForm'
            )
            .style.display =
            'block';


        updateChoices();

    }
    catch (error) {

        document
            .querySelector(
                '#equipmentLoading'
            )
            .textContent =
            'Unable to load starting equipment.';


        showNotice(
            error.message
        );

    }

}

function configureEquipmentChoice(
    packageInfo,
    containerSelector,
    selectSelector
) {

    const container =
        document.querySelector(
            containerSelector
        );


    const select =
        document.querySelector(
            selectSelector
        );


    if (
        !packageInfo ||
        !packageInfo.choiceOptions ||
        packageInfo.choiceOptions.length === 0
    ) {

        container.style.display =
            'none';


        select.innerHTML =
            '';


        return;

    }


    select.innerHTML =
        packageInfo.choiceOptions
            .map(
                choice => `

          <option
            value="${escapeHtml(choice)}"
          >
            ${escapeHtml(choice)}
          </option>

        `
            )
            .join('');


    container.style.display =
        'block';

}

function updateEquipmentPreview(
    classPackage,
    backgroundPackage
) {

    const preview =
        document.querySelector(
            '#equipmentPreview'
        );


    const classChoice =
        document.querySelector(
            '#classEquipmentChoice'
        )?.value || '';


    const backgroundChoice =
        document.querySelector(
            '#backgroundEquipmentChoice'
        )?.value || '';


    const rows = [];


    addPackagePreview(
        rows,
        classPackage,
        classChoice,
        'Class'
    );


    addPackagePreview(
        rows,
        backgroundPackage,
        backgroundChoice,
        'Background'
    );


    preview.innerHTML =
        rows.length === 0
            ?
            `
        <div class="equipment-empty">
          This package grants gold only.
        </div>
      `
            :
            rows
                .map(
                    row => `

            <div class="equipment-preview-row">

              <span class="equipment-source">
                ${escapeHtml(row.source)}
              </span>

              <span class="equipment-item">
                ${escapeHtml(row.item)}
              </span>

              <span class="equipment-qty">
                × ${row.quantity}
              </span>

            </div>

          `
                )
                .join('');


    const gold =
        Number(
            classPackage?.gold || 0
        )
        +
        Number(
            backgroundPackage?.gold || 0
        );


    document
        .querySelector(
            '#startingGold'
        )
        .textContent =
        `${gold} GP`;

}

function addPackagePreview(
    rows,
    packageInfo,
    selectedChoice,
    source
) {

    if (!packageInfo) {
        return;
    }


    for (
        const entry
        of packageInfo.items
    ) {

        let itemName =
            entry.itemName;


        if (
            entry.choiceKind &&
            selectedChoice
        ) {

            itemName =
                selectedChoice;

        }


        rows.push({

            source:
                source,

            item:
                itemName,

            quantity:
                entry.quantity

        });

    }

}

async function saveStartingEquipment(
    campaignId,
    classPackage,
    backgroundPackage
) {

    const button =
        document.querySelector(
            '#saveStartingEquipment'
        );


    const errorBox =
        document.querySelector(
            '#equipmentError'
        );


    errorBox.textContent =
        '';


    button.disabled =
        true;


    button.textContent =
        'Saving Equipment...';


    try {

        const response =
            await fetch(
                `/game-api/campaigns/${campaignId}/starting-equipment`,
                {

                    method:
                        'POST',

                    headers: {

                        'Content-Type':
                            'application/json',

                        'Authorization':
                            `Bearer ${discordAccessToken}`

                    },

                    body:
                        JSON.stringify({

                            classPackageIndex:
                                classPackage.index,

                            classChoice:
                                document
                                    .querySelector(
                                        '#classEquipmentChoice'
                                    )
                                    ?.value || '',

                            backgroundPackageIndex:
                                backgroundPackage.index,

                            backgroundChoice:
                                document
                                    .querySelector(
                                        '#backgroundEquipmentChoice'
                                    )
                                    ?.value || ''

                        })

                }
            );


        const data =
            await response.json();


        if (
            !response.ok ||
            !data.success
        ) {

            throw new Error(
                data.error ||
                'Unable to save starting equipment.'
            );

        }


        showNotice(
            `Starting equipment saved. ${data.gold} GP added.`
        );


        await openCampaign(
            campaignId
        );

    }
    catch (error) {

        console.error(error);


        errorBox.textContent =
            error.message;


        button.disabled =
            false;


        button.textContent =
            'Accept Starting Equipment';

    }

}


function getManualAbility(
    selector
) {

    const value =
        Number(
            document
                .querySelector(
                    selector
                )
                .value
        );


    return Math.max(
        1,
        Math.min(
            20,
            value
        )
    );

}

async function createRandomCharacter(
    campaignId
) {

    const name =
        document
            .querySelector(
                '#newCharacterName'
            )
            .value
            .trim();


    const species =
        document
            .querySelector(
                '#newCharacterSpecies'
            )
            .value;


    const className =
        document
            .querySelector(
                '#newCharacterClass'
            )
            .value;


    const button =
        document.querySelector(
            '#generateCharacter'
        );


    const errorBox =
        document.querySelector(
            '#creatorError'
        );


    errorBox.textContent =
        '';


    button.disabled =
        true;


    button.textContent =
        'Generating...';


    try {

        const response =
            await fetch(
                `/game-api/campaigns/${campaignId}/characters/random`,
                {

                    method:
                        'POST',

                    headers: {

                        'Content-Type':
                            'application/json',

                        'Authorization':
                            `Bearer ${discordAccessToken}`

                    },

                    body:
                        JSON.stringify({

                            characterName:
                                name,

                            species:
                                species,

                            className:
                                className

                        })

                }
            );


        const data =
            await response.json();


        if (
            !response.ok ||
            !data.success
        ) {

            throw new Error(
                data.error ||
                'Character generation failed.'
            );

        }


        await showStartingEquipment(
            campaignId,
            data.character
        );

    }
    catch (error) {

        console.error(error);


        errorBox.textContent =
            error.message;


        button.disabled =
            false;


        button.textContent =
            'Generate Character';

    }

}

function showCharacterReady(
    campaignId,
    character
) {

    const main =
        document.querySelector(
            '#mainContent'
        );


    main.innerHTML = `

    <div class="character-ready">

      <div class="creator-header">

        <div>

          <h2>
            ${escapeHtml(
        character.characterName
    )}
          </h2>

          <p>

            Level
            ${character.level}

            ${escapeHtml(
        character.speciesName
    )}

            ${escapeHtml(
        character.className
    )}

          </p>

        </div>


        <button
          id="characterBack"
          class="small-button"
        >
          Back to Campaigns
        </button>

      </div>


      <section class="character-summary">


        <div class="character-vitals">

          <div>

            <span class="stat-label">
              HP
            </span>

            <strong>
              ${character.currentHp}
              /
              ${character.maxHp}
            </strong>

          </div>


          <div>

            <span class="stat-label">
              AC
            </span>

            <strong>
              ${character.armorClass}
            </strong>

          </div>


          <div>

            <span class="stat-label">
              Initiative
            </span>

            <strong>
              ${formatSigned(
        character.initiative
    )}
            </strong>

          </div>


          <div>

            <span class="stat-label">
              Speed
            </span>

            <strong>
              ${character.speed} ft.
            </strong>

          </div>

        </div>


        <div class="ability-grid">

          ${abilityBox(
        'STR',
        character.strength
    )}

          ${abilityBox(
        'DEX',
        character.dexterity
    )}

          ${abilityBox(
        'CON',
        character.constitution
    )}

          ${abilityBox(
        'INT',
        character.intelligence
    )}

          ${abilityBox(
        'WIS',
        character.wisdom
    )}

          ${abilityBox(
        'CHA',
        character.charisma
    )}

        </div>


        <div class="character-extra">

          <div>

            <span class="stat-label">
              Background
            </span>

            <strong>
              ${escapeHtml(
        character.backgroundName
    )}
            </strong>

          </div>


          <div>

            <span class="stat-label">
              Passive Perception
            </span>

            <strong>
              ${character.passivePerception}
            </strong>

          </div>


          <div>

            <span class="stat-label">
              Proficiency Bonus
            </span>

            <strong>
              ${formatSigned(
        character.proficiencyBonus
    )}
            </strong>

          </div>


          <div>

            <span class="stat-label">
              Gold
            </span>

            <strong>
              ${character.gold}
            </strong>

          </div>

        </div>


        <button
          id="enterCampaign"
          class="enter-campaign-button"
        >
          Enter Campaign
        </button>


        <div class="creator-help">

          The character has been permanently
          saved to this campaign.

        </div>

      </section>

    </div>

  `;


    document
        .querySelector(
            '#characterBack'
        )
        .addEventListener(
            'click',
            showCampaignLauncher
        );


    document
        .querySelector(
            '#enterCampaign'
        )
        .addEventListener(
            'click',
            () => {

                showNotice(
                    'Character ready. Main game screen is next.'
                );

            }
        );

}

function abilityBox(
    name,
    score
) {

    const modifier =
        Math.floor(
            (score - 10) / 2
        );


    return `

    <div class="ability-box">

      <span>
        ${name}
      </span>

      <strong>
        ${score}
      </strong>

      <small>
        ${formatSigned(modifier)}
      </small>

    </div>

  `;

}


function formatSigned(
    value
) {

    const number =
        Number(value || 0);


    return number >= 0
        ? `+${number}`
        : `${number}`;

}


// ========================================================
// NEW CAMPAIGN DIALOG
// ========================================================

function showNewCampaignDialog() {

    showModal({

        title:
            'Start New Campaign',

        body: `

      <label
        class="form-label"
        for="campaignName"
      >
        Campaign Name
      </label>


      <input
        id="campaignName"
        class="game-input"
        type="text"
        maxlength="80"
        placeholder="My Rabu Shin Campaign"
        autocomplete="off"
      />


      <div class="form-help">

        You will be the owner and Game
        Master host for this campaign.

      </div>

    `,

        confirmText:
            'Create Campaign',

        onConfirm:
            async () => {

                const input =
                    document.querySelector(
                        '#campaignName'
                    );


                const name =
                    input.value.trim();


                if (!name) {

                    input.focus();

                    return false;

                }


                try {

                    const response =
                        await fetch(
                            '/game-api/campaigns',
                            {

                                method:
                                    'POST',

                                headers: {

                                    'Content-Type':
                                        'application/json',

                                    'Authorization':
                                        `Bearer ${discordAccessToken}`

                                },

                                body:
                                    JSON.stringify({

                                        campaignName:
                                            name

                                    })

                            }
                        );


                    const data =
                        await response.json();


                    if (
                        !response.ok ||
                        !data.success
                    ) {

                        throw new Error(
                            data.error ||
                            'Campaign could not be created.'
                        );

                    }


                    closeModal();


                    showNotice(
                        'Campaign created successfully.'
                    );


                    await loadCampaigns();


                    return true;

                }
                catch (error) {

                    showNotice(
                        error.message
                    );


                    return false;

                }

            }

    });


    setTimeout(
        () =>
            document
                .querySelector(
                    '#campaignName'
                )
                ?.focus(),
        50
    );

}


// ========================================================
// JOIN CAMPAIGN DIALOG
// ========================================================

function showJoinCampaignDialog() {

    showModal({

        title:
            'Join Campaign',

        body: `

      <label
        class="form-label"
        for="campaignCode"
      >
        Campaign Code
      </label>


      <input
        id="campaignCode"
        class="game-input campaign-code-input"
        type="text"
        maxlength="64"
        placeholder="Enter campaign code"
        autocomplete="off"
      />


      <div class="form-help">

        Ask the campaign owner for their
        campaign code.

      </div>

    `,

        confirmText:
            'Join Campaign',

        onConfirm:
            async () => {

                const input =
                    document.querySelector(
                        '#campaignCode'
                    );


                const code =
                    input.value.trim();


                if (!code) {

                    input.focus();

                    return false;

                }


                try {

                    const response =
                        await fetch(
                            '/game-api/campaigns/join',
                            {

                                method:
                                    'POST',

                                headers: {

                                    'Content-Type':
                                        'application/json',

                                    'Authorization':
                                        `Bearer ${discordAccessToken}`

                                },

                                body:
                                    JSON.stringify({

                                        joinCode:
                                            code

                                    })

                            }
                        );


                    const data =
                        await response.json();


                    if (
                        !response.ok ||
                        !data.success
                    ) {

                        throw new Error(
                            data.error ||
                            'Campaign could not be joined.'
                        );

                    }


                    closeModal();


                    showNotice(
                        'Campaign joined successfully.'
                    );


                    await loadCampaigns();


                    return true;

                }
                catch (error) {

                    showNotice(
                        error.message
                    );


                    return false;

                }

            }

    });

}


// ========================================================
// GENERIC MODAL
// ========================================================

function showModal(options) {

    closeModal();


    const overlay =
        document.createElement(
            'div'
        );


    overlay.id =
        'modalOverlay';


    overlay.className =
        'modal-overlay';


    overlay.innerHTML = `

    <div class="game-modal">

      <h3>
        ${escapeHtml(
        options.title
    )}
      </h3>


      <div class="modal-body">

        ${options.body}

      </div>


      <div class="modal-buttons">

        <button
          id="modalCancel"
          class="small-button"
        >
          Cancel
        </button>


        <button
          id="modalConfirm"
          class="small-button primary-button"
        >

          ${escapeHtml(
        options.confirmText
    )}

        </button>

      </div>

    </div>

  `;


    document.body.appendChild(
        overlay
    );


    document
        .querySelector(
            '#modalCancel'
        )
        .addEventListener(
            'click',
            closeModal
        );


    document
        .querySelector(
            '#modalConfirm'
        )
        .addEventListener(
            'click',
            async () => {

                await options.onConfirm();

            }
        );

}


// ========================================================
// CLOSE MODAL
// ========================================================

function closeModal() {

    document
        .querySelector(
            '#modalOverlay'
        )
        ?.remove();

}


// ========================================================
// NOTICE
// ========================================================

function showNotice(message) {

    const existing =
        document.querySelector(
            '#gameNotice'
        );


    existing?.remove();


    const notice =
        document.createElement(
            'div'
        );


    notice.id =
        'gameNotice';


    notice.className =
        'game-notice';


    notice.textContent =
        message;


    document.body.appendChild(
        notice
    );


    setTimeout(
        () => {

            notice.remove();

        },
        4000
    );

}


// ========================================================
// DEVELOPMENT DICE TEST
// ========================================================

async function testDice() {

    const resultBox =
        document.querySelector(
            '#developerResult'
        );


    resultBox.textContent =
        'Rolling...';


    try {

        const response =
            await fetch(
                '/game-api/dice/roll',
                {

                    method:
                        'POST',

                    headers: {

                        'Content-Type':
                            'application/json'

                    },

                    body:
                        JSON.stringify({

                            count:
                                1,

                            sides:
                                20,

                            modifier:
                                0,

                            advantage:
                                false,

                            disadvantage:
                                false

                        })

                }
            );


        const result =
            await response.json();


        resultBox.textContent =
            `VB.NET D20 Result: ${result.total}`;

    }
    catch (error) {

        resultBox.textContent =
            `Error: ${error.message}`;

    }

}


// ========================================================
// RABUSHIN SERVER STATUS
// ========================================================

async function checkServer() {

    const status =
        document.querySelector(
            '#serverStatus'
        );


    try {

        const response =
            await fetch(
                '/game-api/health'
            );


        const data =
            await response.json();


        if (!data.success) {

            throw new Error();

        }


        status.textContent =
            'RabuShin Server Online';


        status.classList.add(
            'online'
        );

    }
    catch {

        status.textContent =
            'RabuShin Server Offline';


        status.classList.add(
            'offline'
        );

    }

}


// ========================================================
// FATAL ERROR
// ========================================================

function showFatalError(message) {

    const main =
        document.querySelector(
            '#mainContent'
        );


    main.innerHTML = `

    <section class="panel">

      <h2>
        Unable to Start RabuShin
      </h2>

      <p>
        ${escapeHtml(message)}
      </p>

    </section>

  `;

}


// ========================================================
// HTML SAFETY
// ========================================================

function escapeHtml(value) {

    return String(
        value ?? ''
    )

        .replaceAll(
            '&',
            '&amp;'
        )

        .replaceAll(
            '<',
            '&lt;'
        )

        .replaceAll(
            '>',
            '&gt;'
        )

        .replaceAll(
            '"',
            '&quot;'
        )

        .replaceAll(
            "'",
            '&#039;'
        );

}


// ========================================================
// START
// ========================================================

checkServer();

setupDiscord();