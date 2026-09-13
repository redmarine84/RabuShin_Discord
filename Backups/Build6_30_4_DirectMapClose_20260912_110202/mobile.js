/* RabuShinAIGM Build 6.30.3 - Discord Mobile Support
   Desktop Discord is preserved, but Discord mobile Activities are now
   detected with a stronger narrow-viewport fallback.
*/

(() => {
  'use strict';

  const ua = navigator.userAgent || '';
  const platform = navigator.platform || '';
  const uaDataMobile = navigator.userAgentData?.mobile === true;
  const maxTouchPoints = Number(navigator.maxTouchPoints || 0);

  const isAppleTouchDesktop =
    platform === 'MacIntel' && maxTouchPoints > 1;

  const isAndroidUa = /Android/i.test(ua);
  const isIOSUa = /iPhone|iPad|iPod/i.test(ua) || isAppleTouchDesktop;

  const isWindowsDesktop =
    /Windows/i.test(ua) || /Win32|Win64|WinCE/i.test(platform);

  const isMacDesktop =
    !isAppleTouchDesktop &&
    (/Macintosh/i.test(ua) || /MacIntel|MacPPC|Mac68K/i.test(platform));

  const coarsePointer =
    typeof window.matchMedia === 'function' &&
    window.matchMedia('(pointer: coarse)').matches;

  const touchCapable = maxTouchPoints > 0 || coarsePointer;

  const screenW = Number(window.screen?.width || 0);
  const screenH = Number(window.screen?.height || 0);
  const viewW = Number(window.innerWidth || 0);
  const viewH = Number(window.innerHeight || 0);

  const shortViewport = Math.min(
    ...( [screenW, screenH, viewW, viewH].filter(v => Number.isFinite(v) && v > 0) )
  );

  const narrowViewport = shortViewport > 0 && shortViewport <= 600;
  const touchTabletOrPhone = touchCapable && shortViewport > 0 && shortViewport <= 1100;

  const isMobileByCapabilities =
    !isWindowsDesktop &&
    !isMacDesktop &&
    touchTabletOrPhone;

  const isForcedMobileLayout =
    narrowViewport || (touchCapable && Math.min(viewW || 99999, viewH || 99999) <= 600);

  /*
    Final activation rule:
    - obvious Android/iOS
    - UAData mobile
    - capability-based mobile
    - OR very narrow/touch viewport (Discord mobile iframe fallback)
  */
  const isDiscordMobile =
    isAndroidUa ||
    isIOSUa ||
    uaDataMobile ||
    isMobileByCapabilities ||
    isForcedMobileLayout;

  if (!isDiscordMobile) {
    console.info('[RabuShin Mobile] Desktop mode retained.', {
      ua, platform, maxTouchPoints, viewW, viewH, screenW, screenH
    });
    return;
  }

  const root = document.documentElement;
  root.classList.add('rs-mobile');

  const detectedAndroid =
    isAndroidUa ||
    (!isIOSUa && !isAppleTouchDesktop && /Linux/i.test(platform + ' ' + ua));

  if (detectedAndroid) root.classList.add('rs-mobile-android');
  if (isIOSUa || isAppleTouchDesktop) root.classList.add('rs-mobile-ios');
  if (isMobileByCapabilities) root.classList.add('rs-mobile-capability-detected');
  if (isForcedMobileLayout) root.classList.add('rs-mobile-forced-viewport');

  root.dataset.rsMobileDetection =
    isAndroidUa ? 'android-ua' :
    isIOSUa ? 'ios-ua' :
    uaDataMobile ? 'ua-data-mobile' :
    isMobileByCapabilities ? 'touch-capabilities' :
    'forced-narrow-viewport';

  console.info(`[RabuShin Mobile] Activated (${root.dataset.rsMobileDetection}).`);

  const mobileLabels = {
    gm: 'GM',
    character: 'Character',
    inventory: 'Inventory',
    spells: 'Spells',
    journal: 'Journal',
    chat: 'Chat',
    settings: 'Settings',
    combat: 'Combat',
    party: 'Party',
  };

  let enhancementFrame = 0;
  let baselineViewportHeight = 0;

  function updateViewportMetrics() {
    const vv = window.visualViewport;
    const height = vv?.height || window.innerHeight || 0;
    const width = vv?.width || window.innerWidth || 0;

    if (height > baselineViewportHeight) baselineViewportHeight = height;

    root.style.setProperty('--rs-vvh', `${Math.max(1, height)}px`);
    root.style.setProperty('--rs-vvw', `${Math.max(1, width)}px`);

    const keyboardLikelyOpen =
      baselineViewportHeight > 0 &&
      height < baselineViewportHeight - 140;

    root.classList.toggle('rs-keyboard-open', keyboardLikelyOpen);
  }

  function compactGameTabs() {
    document.querySelectorAll('.game-tab').forEach((button) => {
      const tab = button.dataset.tab;
      if (!tab) return;

      if (!button.dataset.desktopLabel) {
        button.dataset.desktopLabel = button.textContent.trim();
      }

      const label = mobileLabels[tab] || button.dataset.desktopLabel;
      button.dataset.mobileLabel = label;
      button.title = button.dataset.desktopLabel;
      button.setAttribute('aria-label', button.dataset.desktopLabel);
    });
  }

  function improveInputs() {
    document.querySelectorAll('input, textarea, select').forEach((control) => {
      if (control.dataset.rsMobileInputBound === 'true') return;
      control.dataset.rsMobileInputBound = 'true';

      control.addEventListener('focus', () => {
        setTimeout(() => {
          updateViewportMetrics();
          control.scrollIntoView({
            block: 'center',
            inline: 'nearest',
            behavior: 'smooth',
          });
        }, 220);
      });

      control.addEventListener('blur', () => {
        setTimeout(updateViewportMetrics, 180);
      });
    });
  }

  function bindTacticalTouch(viewport) {
    if (!viewport || viewport.dataset.rsMobileTouchBound === 'true') return;
    viewport.dataset.rsMobileTouchBound = 'true';

    let pinchDistance = 0;
    let suppressClickUntil = 0;
    let oneFingerStart = null;

    const distance = (touches) => {
      if (!touches || touches.length < 2) return 0;
      const dx = touches[0].clientX - touches[1].clientX;
      const dy = touches[0].clientY - touches[1].clientY;
      return Math.hypot(dx, dy);
    };

    viewport.addEventListener('touchstart', (event) => {
      if (event.touches.length === 2) {
        pinchDistance = distance(event.touches);
        oneFingerStart = null;
      } else if (event.touches.length === 1) {
        oneFingerStart = {
          x: event.touches[0].clientX,
          y: event.touches[0].clientY,
        };
      }
    }, { passive: true });

    viewport.addEventListener('touchmove', (event) => {
      if (event.touches.length === 2) {
        const nextDistance = distance(event.touches);

        if (!pinchDistance) {
          pinchDistance = nextDistance;
          return;
        }

        const ratio = nextDistance / pinchDistance;

        if (ratio >= 1.16) {
          document.querySelector('#tacticalZoomIn')?.click();
          pinchDistance = nextDistance;
          suppressClickUntil = Date.now() + 450;
        } else if (ratio <= 0.86) {
          document.querySelector('#tacticalZoomOut')?.click();
          pinchDistance = nextDistance;
          suppressClickUntil = Date.now() + 450;
        }
        return;
      }

      if (event.touches.length === 1 && oneFingerStart) {
        const dx = event.touches[0].clientX - oneFingerStart.x;
        const dy = event.touches[0].clientY - oneFingerStart.y;
        if (Math.hypot(dx, dy) > 12) {
          suppressClickUntil = Date.now() + 180;
        }
      }
    }, { passive: true });

    viewport.addEventListener('touchend', (event) => {
      if (event.touches.length < 2) pinchDistance = 0;
      if (event.touches.length === 0) oneFingerStart = null;
    }, { passive: true });

    viewport.addEventListener('click', (event) => {
      if (Date.now() < suppressClickUntil) {
        event.preventDefault();
        event.stopImmediatePropagation();
      }
    }, true);
  }

  function improveTacticalMap() {
    const viewport = document.querySelector('#tacticalViewport');
    if (!viewport) return;

    bindTacticalTouch(viewport);

    viewport.setAttribute(
      'aria-label',
      'Encounter map. Drag to pan, pinch or use the zoom buttons to zoom, and tap tokens or map squares to interact.'
    );

    const zoomOut = document.querySelector('#tacticalZoomOut');
    const zoomIn = document.querySelector('#tacticalZoomIn');
    const fit = document.querySelector('#tacticalFit');

    if (zoomOut) zoomOut.setAttribute('aria-label', 'Zoom encounter map out');
    if (zoomIn) zoomIn.setAttribute('aria-label', 'Zoom encounter map in');
    if (fit) fit.setAttribute('aria-label', 'Fit encounter map to screen');
  }

  function improveModalAccessibility() {
    document.querySelectorAll('.modal-overlay').forEach((overlay) => {
      if (!overlay.hasAttribute('role')) overlay.setAttribute('role', 'dialog');
      overlay.setAttribute('aria-modal', 'true');
    });
  }

  function relocateMapCloseButtons() {
    const localClose = document.querySelector('#closeLocalMap');
    const localFit = document.querySelector('#localMapFit');
    if (localClose && localFit && localClose.dataset.rsRelocated !== 'true') {
      localClose.dataset.rsRelocated = 'true';
      localClose.classList.add('rs-inline-map-close', 'button');
      localFit.insertAdjacentElement('afterend', localClose);
    }

    const worldClose = document.querySelector('#closeWorldMap');
    const worldFit = document.querySelector('#worldMapFit');
    if (worldClose && worldFit && worldClose.dataset.rsRelocated !== 'true') {
      worldClose.dataset.rsRelocated = 'true';
      worldClose.classList.add('rs-inline-map-close', 'button');
      worldFit.insertAdjacentElement('afterend', worldClose);
    }
  }

  function enhance() {
    compactGameTabs();
    improveInputs();
    improveTacticalMap();
    improveModalAccessibility();
    relocateMapCloseButtons();
    updateViewportMetrics();
  }

  function scheduleEnhance() {
    if (enhancementFrame) return;
    enhancementFrame = requestAnimationFrame(() => {
      enhancementFrame = 0;
      enhance();
    });
  }

  const observer = new MutationObserver(scheduleEnhance);
  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
  });

  window.addEventListener('resize', updateViewportMetrics, { passive: true });

  window.addEventListener('orientationchange', () => {
    baselineViewportHeight = 0;
    setTimeout(() => {
      updateViewportMetrics();
      scheduleEnhance();
    }, 180);
  }, { passive: true });

  if (window.visualViewport) {
    window.visualViewport.addEventListener('resize', updateViewportMetrics, { passive: true });
    window.visualViewport.addEventListener('scroll', updateViewportMetrics, { passive: true });
  }

  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) {
      baselineViewportHeight = 0;
      updateViewportMetrics();
      scheduleEnhance();
    }
  });

  updateViewportMetrics();
  scheduleEnhance();
})();
