/* Small interaction layer for the dense console. Existing dashboard JS owns data. */
(function () {
  function install() {
    document.body.classList.add('noc-console');
    var tabs = document.querySelectorAll('.tab-btn');
    for (var i = 0; i < tabs.length; i++) {
      tabs[i].title = (tabs[i].textContent || '').replace(/\s+/g, ' ').trim();
    }
    var packetBody = document.getElementById('dash-packets-tbody');
    if (packetBody && window.MutationObserver) {
      var observer = new MutationObserver(function () {
        packetBody.setAttribute('data-last-update', new Date().toISOString());
      });
      observer.observe(packetBody, { childList: true });
    }
  }

  document.addEventListener('keydown', function (event) {
    var tag = (event.target && event.target.tagName) || '';
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;
    var routes = { '1': 'dashboard', '2': 'pipeline', '3': 'decoders', '4': 'nodes' };
    if (routes[event.key] && typeof window.switchTab === 'function') {
      window.switchTab(routes[event.key]);
    }
  });

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', install);
  else install();
}());
