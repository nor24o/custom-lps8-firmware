/* Headless interaction checks. Writes to decoder/profile APIs are isolated. */
const {chromium}=require('../.console-test-tools/node_modules/playwright-core');
const assert=require('node:assert/strict');
const base=process.env.CONSOLE_TEST_URL || 'http://127.0.0.1:5080';
(async()=>{
  const browser=await chromium.launch({executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:true});
  try {
    const page=await browser.newPage({viewport:{width:1440,height:1050}});
    const errors=[];page.on('pageerror',e=>errors.push(e.message));
    let savedConfig=null,savedProfiles=null;
    await page.route('**/api/**',async route=>{
      const req=route.request(),path=new URL(req.url()).pathname;
      if(path==='/api/lora/decoders/test'||path==='/api/lora/profiles/test')return route.continue();
      if(path==='/api/lora/profiles'&&req.method()==='POST'){savedProfiles=req.postDataJSON();return route.fulfill({json:{success:true,profiles:savedProfiles.profiles}});}
      if(path==='/api/lora/profiles'&&savedProfiles)return route.fulfill({json:savedProfiles});
      if(path==='/api/lora/decoders'&&req.method()==='POST'){
        savedConfig=req.postDataJSON();return route.fulfill({json:{success:true}});
      }
      if(path==='/api/lora/decoders'&&savedConfig)return route.fulfill({json:savedConfig});
      if(req.method()!=='GET')throw new Error('Unexpected external write: '+path);
      const response=await route.fetch({url:'http://192.168.1.15'+path});
      return route.fulfill({response});
    });
    await page.goto(base+'/#decoders');
    await page.locator('#schemes-table tbody tr').filter({hasText:'Node CAFE'}).waitFor();
    await page.locator('#studio-hex').fill('CAFE96B840EB0102014A02710004001904280367010404880000000000000000000500480600E0');
    await page.locator('#studio-scheme').selectOption('scheme_node_cafe');
    assert.match(await page.locator('#studio-result').innerText(),/battery/);
    await page.locator('#studio-server').click();
    await page.locator('#studio-server-result').filter({hasText:'decoded'}).waitFor();
    await page.locator('#full-packet-profiler').click();
    await page.locator('#pf-form').waitFor();
    assert.equal(await page.locator('iframe').count(),0);
    await page.locator('#pf-result .identity-preview').waitFor();
    assert.match(await page.locator('#pf-result').innerText(),/CAFE-96B840EB/);
    await page.locator('#modal-close').click();
    await page.locator('#console-modal').waitFor({state:'hidden'});
    await page.locator('[data-byte="0"]').first().click();
    await page.locator('#console-modal[open]').waitFor();
    assert.match(await page.locator('#modal-content').innerText(),/unsigned: 202/);
    await page.keyboard.press('Escape');
    await page.locator('[data-byte="2"]').first().click({modifiers:['Shift']});
    await page.locator('#scheme-editor').waitFor();
    assert.ok(await page.locator('[data-key="offset"]').count()>0);
    await page.locator('#draft-cancel').click();
    await page.locator('#schemes-table tr').filter({hasText:'Node CAFE'}).getByRole('button',{name:'Edit & test'}).click();
    await page.locator('#native-auto-slice').click();
    assert.ok(await page.locator('#draft-fields [data-key="name"]').count()>5);
    await page.getByRole('button',{name:'Generate JavaScript parser',exact:true}).click();
    assert.match(await page.locator('#native-js-code').inputValue(),/DataView/);
    if(base.includes('192.168.1.15')){await page.locator('#draft-verify').click();await page.locator('#draft-server-result').filter({hasText:'temperature'}).waitFor();}
    assert.equal(await page.locator('#draft-json').isVisible(),false);
    await page.locator('#draft-cancel').click();
    await page.locator('#new-scheme').click();
    await page.locator('#draft-name').fill('Verification draft');
    await page.locator('#draft-id').fill('verification_draft');
    await page.locator('#draft-add').click();
    await page.locator('[data-key="name"]').fill('first_byte');
    await page.locator('#draft-verify').click();
    await page.locator('#draft-server-result').filter({hasText:'first_byte'}).waitFor();
    await page.locator('#scheme-editor button.primary').click();
    await page.locator('#schemes-table').filter({hasText:'Verification draft'}).waitFor();
    assert.ok(savedConfig.schemes.some(s=>s.id==='verification_draft'));
    await page.locator('#schemes-table tr').filter({hasText:'Verification draft'}).getByRole('button',{name:'Edit & test'}).click();
    await page.locator('#scheme-editor').waitFor();
    await page.locator('#draft-cancel').click();
    await page.screenshot({path:'C:/Users/horva/.codex/visualizations/2026/11/08/01a1bc88-60f4-7561-ae61-5ce6143910d8/decoder-studio.png'});
    await page.goto(base+'/#traffic');
    await page.locator('#traffic-table [data-event]').first().click();
    await page.locator('#inspect-decode').click();
    await page.locator('#decoders:not([hidden])').waitFor();
    await page.goto(base+'/#devices');
    await page.getByRole('button',{name:'Register a device',exact:true}).click();
    await page.locator('#console-modal[open] #enroll-form').waitFor();
    await page.keyboard.press('Escape');
    await page.goto(base+'/#overview');
    await page.locator('.activity-row').first().waitFor();
    assert.equal(await page.locator('.activity-detail:visible').count(),0);
    assert.ok(await page.locator('.activity-decoded .telemetry-value').count()>0);
    const activityKey=await page.locator('.activity-row').first().getAttribute('data-activity');
    await page.locator('.activity-row').first().click();
    await page.locator('.activity-detail:visible').first().waitFor();
    assert.match(await page.locator('.activity-detail:visible').innerText(),/Raw payload/);
    await page.waitForTimeout(3500);
    assert.equal(await page.locator('[data-activity]').evaluateAll((rows,key)=>rows.find(row=>row.dataset.activity===key).querySelector('button').getAttribute('aria-expanded'),activityKey),'true');
    await page.locator('.activity-row').first().click();
    for(const view of ['automations','transmit','network','hardware','system']){
      await page.goto(base+'/#'+view);
      await page.locator('#'+view+':not([hidden])').waitFor();
      assert.equal(await page.locator('#'+view+' iframe').count(),0);
    }
    await page.goto(base+'/#automations');await page.locator('#automation-new').click();await page.locator('#management-form').waitFor();await page.locator('#management-cancel').click();
    await page.goto(base+'/#transmit');await page.locator('#tx-compose').click();await page.locator('#management-form [name="payload_hex"]').waitFor();await page.locator('#management-form [name="payload_hex"]').fill('0101');await page.locator('#tx-airtime-preview').filter({hasText:'2 bytes'}).waitFor();await page.locator('#management-cancel').click();
    await page.goto(base+'/#system');await page.locator('#system-reboot').click();await page.locator('#cancel-management').click();
    await page.goto(base+'/#devices');await page.locator('[data-device-edit]').first().click();await page.locator('#management-form [name="ha_enabled"]').waitFor();await page.locator('#management-cancel').click();
    for(const section of ['mqtt','udp','pipeline','radio','downlinks']){
      await page.goto(base+'/#'+section);
      await page.locator('#native-config-form').waitFor();
      assert.ok(await page.locator('#native-config-form input').count()>0);
      assert.equal(await page.locator('#settings textarea:visible').count(),0);
    }
    await page.goto(base+'/#profiles');
    await page.locator('#profile-packet').click();
    await page.locator('#pf-form').waitFor();
    await page.locator('#pf-name').fill('Verification profile');
    await page.screenshot({path:'C:/Users/horva/.codex/visualizations/2026/11/08/01a1bc88-60f4-7561-ae61-5ce6143910d8/native-profiler.png'});
    await page.locator('#pf-form button.primary').click();
    await page.locator('#native-profiles').filter({hasText:'Verification profile'}).waitFor();
    assert.ok(savedProfiles.profiles.some(p=>p.name==='Verification profile'));
    await page.goto(base+'/#devices');
    await page.getByRole('button',{name:'Register a device',exact:true}).click();
    await page.locator('#console-modal[open] #enroll-form').waitFor();
    await page.keyboard.press('Escape');
    assert.deepEqual(errors,[]);
    console.log('PASS: native profiler, auto-slicer, scheme editor/save, settings forms without JSON, packet inspection and enrollment dialogs; no page errors.');
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
