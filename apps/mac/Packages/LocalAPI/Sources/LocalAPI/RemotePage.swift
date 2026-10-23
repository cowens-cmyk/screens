import Foundation

/// The phone/tablet remote: one self-contained page served at `/` and `/remote`.
/// The page itself needs no auth; every API call it makes carries the token.
///
/// Two views, picked on first open and remembered on the phone: the booth's
/// (the live and next slides as pictures, big Back and Next, clears, slides,
/// timers, macros, stage messages) and the stage's, for a pastor or worship
/// leader (the sermon timer, the time, the next slide's words, and quick notes
/// to the booth).
public enum RemotePage {
    public static let manifestPath = "/remote.webmanifest"

    public static func html(serviceName: String) -> String {
        template.replacingOccurrences(of: "__SERVICE_NAME__", with: escape(serviceName))
    }

    /// Lets a phone keep the remote on its home screen as its own app. No
    /// start_url: the remote opens where it was added, so the access code in
    /// its address (#t=) comes along.
    public static func manifest(serviceName: String) -> String {
        let name = jsonString(serviceName.isEmpty ? "Screens Remote" : "\(serviceName) Remote")
        return """
        {"name":\(name),"short_name":"Remote","display":"standalone","orientation":"any",\
        "background_color":"#0b0d10","theme_color":"#0b0d10","scope":"/",\
        "icons":[{"src":"/remote-icon-192.png","sizes":"192x192","type":"image/png"},\
        {"src":"/remote-icon-512.png","sizes":"512x512","type":"image/png"}]}
        """
    }

    private static func jsonString(_ text: String) -> String {
        let data = (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static let template = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Remote">
<meta name="theme-color" content="#0b0d10">
<meta name="color-scheme" content="dark">
<link rel="manifest" href="/remote.webmanifest">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="icon" type="image/png" href="/remote-icon-192.png">
<title>Remote</title>
<style>
:root{--bg:#0b0d10;--card:#171b21;--card2:#1f252d;--line:#2a313b;--text:#f2f5f8;--dim:#8b96a3;--accent:#0082ca;--ok:#22c55e;--bad:#ef4444;--warn:#f59e0b}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;height:100%;background:var(--bg);color:var(--text);font:16px/1.35 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;touch-action:manipulation;-webkit-user-select:none;user-select:none;overscroll-behavior:none}
body{padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)}
#app,#stage{display:none;flex-direction:column;height:100%;max-width:900px;margin:0 auto}
header{display:flex;align-items:center;gap:10px;padding:10px 14px;border-bottom:1px solid var(--line)}
.dot{width:12px;height:12px;border-radius:50%;background:var(--bad);flex:none}
.dot.on{background:var(--ok)}.dot.poll{background:var(--warn)}
.title{font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sub{color:var(--dim);font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.swap{flex:none;background:none;border:1px solid var(--line);border-radius:10px;color:var(--dim);font-size:14px;padding:8px 12px;min-height:40px}
nav{display:flex;gap:6px;padding:8px 14px;overflow-x:auto}
nav button{flex:1;padding:10px 6px;min-height:44px;border-radius:10px;border:1px solid var(--line);background:var(--card);color:var(--dim);font-size:15px;font-weight:600}
nav button.act{background:var(--accent);color:#fff;border-color:var(--accent)}
main{flex:1;overflow-y:auto;-webkit-overflow-scrolling:touch;padding:8px 14px 20px}
.tab{display:none}.tab.act{display:block}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:12px;margin-bottom:10px}
.lab{color:var(--dim);font-size:12px;text-transform:uppercase;letter-spacing:.08em;margin-bottom:6px}
.frame{position:relative;width:100%;aspect-ratio:16/9;background:#000;border-radius:10px;overflow:hidden;border:1px solid var(--line)}
.frame img{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;display:none}
.frame img.on{display:block}
.frame .say{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;padding:10px;text-align:center;color:var(--dim);font-size:15px;white-space:pre-wrap;overflow:hidden}
.frame.live{border:2px solid var(--ok)}
.nextrow{display:flex;gap:10px;align-items:stretch}
.nextrow .frame{flex:0 0 46%}
.nextrow .words{flex:1;min-width:0;font-size:15px;color:#c3cbd5;white-space:pre-wrap;word-break:break-word;overflow:hidden;max-height:7.5em}
.row{display:flex;gap:10px;margin-bottom:10px}
button{font:inherit;color:var(--text);border:0;cursor:pointer}
.btn{flex:1;border-radius:14px;background:var(--card2);border:1px solid var(--line);padding:14px 8px;min-height:52px;font-weight:600;transition:background .12s,transform .08s}
.btn.flash,.btn:active{background:var(--accent);transform:scale(.97)}
.big{font-size:clamp(24px,7vw,40px);font-weight:800;min-height:clamp(84px,14vh,150px)}
.big.next{background:#0067a3;border-color:#0067a3;flex:1.6}
.big.next.flash,.big.next:active{background:#3aa3e0}
.clr{color:#fecaca;font-size:15px}
.clr.all{background:#7f1d1d;border-color:#991b1b}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(130px,1fr));gap:8px}
.slide{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:8px;min-height:84px;text-align:left;font-size:13px;overflow:hidden;display:block;width:100%}
.slide b{display:block;color:var(--dim);font-size:11px;margin-bottom:3px}
.slide.live{border-color:var(--ok);box-shadow:0 0 0 2px var(--ok) inset}
.item{display:flex;align-items:center;gap:10px;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:10px 12px;margin-bottom:8px}
.item .n{flex:1;font-weight:600;overflow:hidden;text-overflow:ellipsis}
.item .t{font-variant-numeric:tabular-nums;font-size:22px;font-weight:700}
.item .t.run{color:var(--ok)}.item .t.over{color:var(--bad)}
.item .btn{flex:none;min-width:64px;padding:12px 10px}
.fire{width:100%;display:block;text-align:left;margin-bottom:8px;font-size:17px;padding:16px}
textarea,input[type=text]{-webkit-user-select:text;user-select:text}
.msg{width:100%;font:inherit;font-size:18px;padding:12px;border-radius:12px;border:1px solid var(--line);background:var(--card);color:var(--text);margin-bottom:10px;resize:none}
#toast{position:fixed;left:50%;bottom:calc(16px + env(safe-area-inset-bottom));transform:translateX(-50%);background:#7f1d1d;color:#fff;padding:10px 16px;border-radius:10px;opacity:0;pointer-events:none;transition:opacity .2s;max-width:90%;z-index:9}
#toast.show{opacity:1}#toast.good{background:#166534}
.pane{display:none;padding:30px 20px;max-width:480px;margin:0 auto}
#gate input{width:100%;padding:14px;font-size:17px;border-radius:12px;border:1px solid var(--line);background:var(--card);color:var(--text);margin:14px 0}
.pane p{color:var(--dim)}
.role{display:block;width:100%;text-align:left;padding:18px;margin-bottom:12px;border-radius:16px;background:var(--card);border:1px solid var(--line)}
.role b{display:block;font-size:20px;margin-bottom:4px}.role span{color:var(--dim);font-size:15px}
.empty{color:var(--dim);text-align:center;padding:24px}
#sermon{font-variant-numeric:tabular-nums;font-weight:800;font-size:clamp(64px,22vw,150px);line-height:1;text-align:center;color:var(--ok);padding:10px 0}
#sermon.over{color:var(--bad)}#sermon.idle{color:var(--dim)}
#sermonState{text-align:center;color:var(--dim);font-size:14px}
#clock{font-variant-numeric:tabular-nums;font-weight:700;font-size:clamp(32px,10vw,56px);text-align:center}
#stageNext{font-size:clamp(20px,5.5vw,30px);font-weight:600;white-space:pre-wrap;word-break:break-word;min-height:1.4em}
.quick{display:grid;grid-template-columns:1fr 1fr 1fr;gap:10px;margin-bottom:10px}
.quick .btn{min-height:64px;font-size:17px}
</style>
</head>
<body data-service="__SERVICE_NAME__">
<div id="gate" class="pane">
  <h2>Enter access code</h2>
  <p>Scan the code in the Mac app's Settings &rsaquo; Network &amp; API, or paste the access code from there.</p>
  <input id="tokenIn" type="text" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="Access code">
  <button class="btn" id="tokenGo" style="width:100%">Connect</button>
  <p id="gateErr" style="color:var(--bad)"></p>
</div>
<div id="roles" class="pane">
  <h2>Who is using this phone?</h2>
  <p>You can switch later from the top of the screen.</p>
  <button class="role" data-role="booth"><b>Booth</b><span>Run the slides: Back, Next, clears, timers.</span></button>
  <button class="role" data-role="stage"><b>Pastor or worship leader</b><span>Sermon timer, the time, the next slide, and notes to the booth.</span></button>
</div>
<div id="app">
  <header><span class="dot"></span><div style="flex:1;min-width:0"><div class="title"></div><div class="sub" id="sub"></div></div><button class="swap">Switch</button></header>
  <nav>
    <button data-tab="show" class="act">Show</button>
    <button data-tab="slides">Slides</button>
    <button data-tab="timers">Timers</button>
    <button data-tab="macros">Macros</button>
    <button data-tab="stage">Stage</button>
  </nav>
  <main>
    <section class="tab act" id="tab-show">
      <div class="card"><div class="lab">On screen</div>
        <div class="frame" id="liveFrame"><img id="liveImg" alt=""><div class="say" id="cur">&mdash;</div></div>
      </div>
      <div class="card"><div class="lab">Next</div>
        <div class="nextrow"><div class="frame" id="nextFrame"><img id="nextImg" alt=""><div class="say">&mdash;</div></div><div class="words" id="nxt">&mdash;</div></div>
      </div>
      <div class="row">
        <button class="btn big" id="prev">&#9664; Back</button>
        <button class="btn big next" id="next">Next &#9654;</button>
      </div>
      <div class="row">
        <button class="btn clr" data-clear="slides">Clear Slide</button>
        <button class="btn clr" data-clear="media">Clear Media</button>
        <button class="btn clr all" id="clearAll">Clear All</button>
      </div>
    </section>
    <section class="tab" id="tab-slides"><div class="grid" id="grid"></div></section>
    <section class="tab" id="tab-timers"><div id="timers"></div></section>
    <section class="tab" id="tab-macros"><div id="macros"></div></section>
    <section class="tab" id="tab-stage">
      <div class="card"><div class="lab">On stage now</div><div id="stageNow">&mdash;</div></div>
      <textarea id="stageMsg" class="msg" rows="3" placeholder="Message to stage"></textarea>
      <div class="row">
        <button class="btn big next" id="stageSend">Send to Stage</button>
        <button class="btn clr" id="stageClear">Clear</button>
      </div>
    </section>
  </main>
</div>
<div id="stage">
  <header><span class="dot"></span><div style="flex:1;min-width:0"><div class="title"></div><div class="sub">Stage</div></div><button class="swap">Switch</button></header>
  <main>
    <div class="card"><div class="lab">Sermon</div><div id="sermon" class="idle">&mdash;</div><div id="sermonState"></div></div>
    <div class="card"><div class="lab">Time</div><div id="clock">&mdash;</div></div>
    <div class="card"><div class="lab">Next slide</div><div id="stageNext">&mdash;</div></div>
    <div class="card"><div class="lab">Message the booth</div>
      <div class="quick">
        <button class="btn" data-say="Need help">Need help</button>
        <button class="btn" data-say="Mic issue">Mic issue</button>
        <button class="btn" data-say="Ready">Ready</button>
      </div>
      <textarea id="boothMsg" class="msg" rows="2" maxlength="200" placeholder="Something else"></textarea>
      <button class="btn" id="boothSend" style="width:100%">Send to Booth</button>
    </div>
  </main>
</div>
<div id="toast"></div>
<script>
(function(){
"use strict";
var KEY="remoteToken", ROLE="remoteRole", token="", role="", status=null, ws=null, pollTimer=null, wsFails=0, retry=1000, deck=null, deckId=null, lastFire=0, activeTab="show", timerList=[];
var frames={live:{want:"",have:"",busy:false,url:""},next:{want:"",have:"",busy:false,url:""}};
var $=function(id){return document.getElementById(id)};
var all=function(sel){return Array.prototype.slice.call(document.querySelectorAll(sel))};
var serviceName=document.body.getAttribute("data-service")||"";

function store(k,v){try{if(v===null)localStorage.removeItem(k);else if(v!==undefined)localStorage.setItem(k,v);return localStorage.getItem(k)}catch(e){return null}}
function init(){
  var q=new URLSearchParams(location.search), h=new URLSearchParams(location.hash.slice(1)), t=q.get("token")||h.get("t");
  if(t){
    store(KEY,t);q.delete("token");var s=q.toString();
    // The code moves from the query to the fragment: it never reaches a
    // server or a referrer from there, and a phone that keeps the remote on
    // its home screen keeps the code with it (home-screen apps get storage
    // of their own).
    history.replaceState(null,"",location.pathname+(s?"?"+s:"")+"#t="+encodeURIComponent(t));
  }
  token=store(KEY)||"";
  role=store(ROLE)||"";
  all(".title").forEach(function(e){e.textContent=serviceName});
  if(!token)gate();else if(!role)pickRole();else start();
}
function hideAll(){["gate","roles","app","stage"].forEach(function(id){$(id).style.display="none"})}
function gate(msg){
  stop();hideAll();$("gate").style.display="block";$("gateErr").textContent=msg||"";
}
function pickRole(){hideAll();$("roles").style.display="block"}
all(".role").forEach(function(b){b.onclick=function(){role=b.getAttribute("data-role");store(ROLE,role);start()}});
all(".swap").forEach(function(b){b.onclick=function(){pickRole()}});
$("tokenGo").onclick=function(){var v=$("tokenIn").value.trim();if(!v)return;token=v;store(KEY,v);if(!role)pickRole();else start()};
function start(){
  hideAll();
  $(role==="stage"?"stage":"app").style.display="flex";
  refresh();loadTimers();
  if(!ws)connectWS();
  if(role!=="stage")loadMacros();
}
function stop(){
  if(ws){try{ws.onclose=null;ws.close()}catch(e){}ws=null}
  if(pollTimer){clearInterval(pollTimer);pollTimer=null}
}
function toast(m,good){var e=$("toast");e.textContent=m;e.className="show"+(good?" good":"");clearTimeout(toast.t);toast.t=setTimeout(function(){e.className=""},2600)}

function api(method,path,body){
  var o={method:method,headers:{"Authorization":"Bearer "+token}};
  if(body!==undefined){o.headers["Content-Type"]="application/json";o.body=JSON.stringify(body)}
  return fetch(path,o).then(function(r){
    if(r.status===401){store(KEY,null);token="";gate("That access code was not accepted.");throw new Error("unauthorized")}
    return r.text().then(function(t){
      var j=null;try{j=t?JSON.parse(t):null}catch(e){}
      if(!r.ok)throw new Error((j&&j.message)||("Error "+r.status));
      return j;
    });
  });
}
function act(method,path,body,after){
  return api(method,path,body).then(function(r){if(after)after(r);return r}).catch(function(e){if(e.message!=="unauthorized")toast(e.message)});
}
function guard(){var n=Date.now();if(n-lastFire<250)return false;lastFire=n;return true}
function flash(el){el.classList.add("flash");setTimeout(function(){el.classList.remove("flash")},180);if(navigator.vibrate)try{navigator.vibrate(12)}catch(e){}}

function refresh(){
  return api("GET","/v1/status").then(function(s){status=s;render()}).catch(function(e){if(e.message!=="unauthorized")setDot("off")});
}
function setDot(m){all(".dot").forEach(function(d){d.className="dot"+(m==="ws"?" on":m==="poll"?" poll":"")})}
function render(){
  var s=status||{}, live=s.liveSlide||null;
  var name=(live&&live.presentationName)||(s.service&&s.service.name)||"";
  all(".title").forEach(function(e){e.textContent=serviceName+(name?" • "+name:"")});
  var pos=s.position;
  $("sub").textContent=pos&&pos.currentItemName?(pos.currentItemName+(pos.nextItemName?"  →  "+pos.nextItemName:"")):(live&&live.slideCount?("Slide "+((live.slideIndex||0)+1)+" of "+live.slideCount):"");
  $("cur").textContent=live?(live.text||live.slideName||""):"Nothing on screen";
  var nt=(s.nextSlide&&s.nextSlide.text)||s.nextSlideText;
  $("nxt").textContent=nt||"—";
  $("stageNext").textContent=nt||"—";
  if(live&&live.presentationId&&live.presentationId!==deckId)loadDeck(live.presentationId);
  var al=s.alert;
  $("stageNow").textContent=(al&&al.target!=="audience")?al.message:"Nothing";
  $("liveFrame").classList.toggle("live",!!live);
  var nx=s.nextSlide||{};
  frames.live.want=JSON.stringify([live&&live.slideId,live&&live.occurrence,live&&live.stepIndex,s.mediaLayers,s.overlays,al&&al.id]);
  frames.next.want=nx.slideId?JSON.stringify([nx.presentationId,nx.slideId,nx.slideIndex]):"";
  pictures();
  markLive();
}

// The slide pictures: fetched only when what's on screen changes, only while
// the Show tab is in view, one at a time per picture.
function pictures(){
  if(role==="stage"||activeTab!=="show"||document.hidden)return;
  picture("live","liveImg");picture("next","nextImg");
}
function picture(which,imgId){
  var f=frames[which], img=$(imgId);
  if(f.busy||f.want===f.have)return;
  if(!f.want){f.have="";img.classList.remove("on");return}
  var want=f.want;f.busy=true;
  fetch("/v1/show/frames/"+which,{headers:{"Authorization":"Bearer "+token}}).then(function(r){
    if(!r.ok)throw new Error(String(r.status));
    return r.blob();
  }).then(function(b){
    var url=URL.createObjectURL(b);
    img.onload=function(){if(f.url&&f.url!==url)URL.revokeObjectURL(f.url);f.url=url};
    img.src=url;img.classList.add("on");f.have=want;
  }).catch(function(){img.classList.remove("on");f.have=want}).then(function(){f.busy=false;if(f.want!==f.have)picture(which,imgId)});
}
document.addEventListener("visibilitychange",function(){if(!document.hidden&&token){refresh()}});

function loadDeck(id){
  deckId=id;
  api("GET","/v1/documents/presentations/"+encodeURIComponent(id)).then(function(d){deck=d;drawGrid()}).catch(function(){deck=null;drawGrid()});
}
function slideLabel(sl){
  var t="";(sl.objects||[]).forEach(function(o){if(!t&&o.text)t=o.text});
  return t||sl.name||"";
}
function drawGrid(){
  var g=$("grid");g.innerHTML="";
  if(!deck||!deck.slides||!deck.slides.length){g.innerHTML='<div class="empty">No slides live yet.</div>';return}
  deck.slides.forEach(function(sl,i){
    var b=document.createElement("button");b.className="slide";b.setAttribute("data-id",sl.id);
    var n=document.createElement("b");n.textContent=(i+1)+(sl.name?" · "+sl.name:"");
    var t=document.createElement("span");t.textContent=slideLabel(sl).slice(0,90);
    b.appendChild(n);b.appendChild(t);
    b.onclick=function(){if(!guard())return;flash(b);act("POST","/v1/show/slide",{presentationId:deck.id,slideId:sl.id})};
    g.appendChild(b);
  });
  markLive();
}
function markLive(){
  var id=status&&status.liveSlide&&status.liveSlide.slideId;
  all(".slide").forEach(function(e){e.classList.toggle("live",e.getAttribute("data-id")===id)});
}

function loadTimers(){
  api("GET","/v1/timers").then(function(list){timerList=list||[];drawTimers(timerList);drawSermon()}).catch(function(){});
}
function fmt(sec){var neg=sec<0;sec=Math.abs(sec);var h=Math.floor(sec/3600),m=Math.floor(sec%3600/60),s=sec%60;
  return (neg?"-":"")+(h?h+":"+String(m).padStart(2,"0"):m)+":"+String(s).padStart(2,"0")}
function drawTimers(list){
  var el=$("timers");el.innerHTML="";
  if(!list||!list.length){el.innerHTML='<div class="empty">No timers.</div>';return}
  list.forEach(function(t){
    var d=document.createElement("div");d.className="item";
    var n=document.createElement("div");n.className="n";n.textContent=t.name;
    var tm=document.createElement("div");tm.className="t"+(t.running?" run":"")+(t.overrun?" over":"");tm.textContent=fmt(t.displaySeconds);
    d.appendChild(n);d.appendChild(tm);
    [["play","Start","play"],["pause","Pause","pause"],["reset","Reset","reset"]].forEach(function(a){
      if(a[0]==="play"&&t.running)return;
      if(a[0]==="pause"&&!t.running)return;
      var b=document.createElement("button");b.className="btn";b.textContent=a[1];
      b.onclick=function(){if(!guard())return;flash(b);act("POST","/v1/timers/"+encodeURIComponent(t.id)+"/"+a[2],undefined,function(){setTimeout(loadTimers,250)})};
      d.appendChild(b);
    });
    el.appendChild(d);
  });
}
// The same Sermon countdown the Mac's Screens column shows: green while
// there's time, red once it runs past 0:00.
function drawSermon(){
  var t=null;
  timerList.forEach(function(x){if(x.id==="screens.timer.sermon")t=x});
  if(!t)timerList.forEach(function(x){if(!t&&String(x.name).toLowerCase()==="sermon")t=x});
  var el=$("sermon");
  if(!t){el.textContent="—";el.className="idle";$("sermonState").textContent="No sermon timer yet";return}
  el.textContent=fmt(t.displaySeconds);
  el.className=t.overrun?"over":(t.running?"":"idle");
  $("sermonState").textContent=t.overrun?"Over time":(t.running?"Running":"Stopped");
}
function tick(){
  var d=new Date(), h=d.getHours()%12||12;
  $("clock").textContent=h+":"+String(d.getMinutes()).padStart(2,"0");
}
function loadMacros(){
  api("GET","/v1/library/action-combos").then(function(list){
    var el=$("macros");el.innerHTML="";
    if(!list||!list.length){el.innerHTML='<div class="empty">No macros.</div>';return}
    list.forEach(function(c){
      var b=document.createElement("button");b.className="btn fire";b.textContent=c.name;
      b.onclick=function(){if(!guard())return;flash(b);act("POST","/v1/action-combos/"+encodeURIComponent(c.id)+"/fire")};
      el.appendChild(b);
    });
  }).catch(function(){});
}

function advance(n,btn){if(!guard())return;flash(btn);act("POST","/v1/show/advance",{steps:n},function(){if(!ws)refresh()})}
$("next").onclick=function(){advance(1,this)};
$("prev").onclick=function(){advance(-1,this)};
all("[data-clear]").forEach(function(b){b.onclick=function(){if(!guard())return;flash(b);act("POST","/v1/show/clear",{"function":b.getAttribute("data-clear")},function(){if(!ws)refresh()})}});
$("stageSend").onclick=function(){var m=$("stageMsg").value.trim();if(!m||!guard())return;flash(this);act("POST","/v1/alerts/fire",{message:m,behavior:"persist",target:"confidence"},function(){$("stageMsg").value="";if(!ws)refresh()})};
$("stageClear").onclick=function(){if(!guard())return;flash(this);act("POST","/v1/alerts/dismiss",undefined,function(){if(!ws)refresh()})};
$("clearAll").onclick=function(){if(!guard())return;flash(this);act("POST","/v1/show/clear-all",undefined,function(){if(!ws)refresh()})};

function tellBooth(text,btn){
  text=(text||"").trim();if(!text||!guard())return;flash(btn);
  act("POST","/v1/booth/messages",{text:text,from:"Stage"},function(){toast("Sent to the booth",true);$("boothMsg").value=""});
}
all("[data-say]").forEach(function(b){b.onclick=function(){tellBooth(b.getAttribute("data-say"),b)}});
$("boothSend").onclick=function(){tellBooth($("boothMsg").value,this)};

var tabs=all("nav button");
tabs.forEach(function(t){t.onclick=function(){
  activeTab=t.getAttribute("data-tab");
  tabs.forEach(function(k){k.classList.toggle("act",k===t)});
  all(".tab").forEach(function(s){s.classList.toggle("act",s.id==="tab-"+activeTab)});
  if(activeTab==="timers")loadTimers();
  if(activeTab==="macros")loadMacros();
  if(activeTab==="show")pictures();
}});

document.addEventListener("keydown",function(e){
  if(!token||role==="stage"||e.target.tagName==="INPUT"||e.target.tagName==="TEXTAREA")return;
  if(e.key==="ArrowRight"||e.key==="ArrowDown"||e.key===" "||e.key==="PageDown"){e.preventDefault();advance(1,$("next"))}
  else if(e.key==="ArrowLeft"||e.key==="ArrowUp"||e.key==="PageUp"){e.preventDefault();advance(-1,$("prev"))}
});
var lastTouch=0;
document.addEventListener("touchend",function(e){if(e.target.tagName==="TEXTAREA"||e.target.tagName==="INPUT")return;var n=Date.now();if(n-lastTouch<300)e.preventDefault();lastTouch=n},{passive:false});
document.addEventListener("gesturestart",function(e){e.preventDefault()});

function connectWS(){
  if(!token)return;
  var url=(location.protocol==="https:"?"wss://":"ws://")+location.host+"/v1/ws?token="+encodeURIComponent(token);
  var sock;try{sock=new WebSocket(url)}catch(e){startPolling();return}
  ws=sock;var opened=false;
  sock.onopen=function(){
    opened=true;wsFails=0;retry=1000;setDot("ws");
    if(pollTimer){clearInterval(pollTimer);pollTimer=null}
    sock.send(JSON.stringify({type:"subscribe",topics:["show","timers","library"]}));
    refresh();
  };
  sock.onmessage=function(ev){
    var m;try{m=JSON.parse(ev.data)}catch(e){return}
    if(m.type!=="event")return;
    if(m.topic==="show"){if(m.data&&m.data.liveSlide!==undefined){status=m.data;render()}else refresh()}
    else if(m.topic==="timers")loadTimers();
    else if(m.topic==="library"){if(role!=="stage")loadMacros();deckId=null;refresh()}
  };
  sock.onclose=function(){
    if(ws!==sock)return;ws=null;
    if(!opened)wsFails++;
    if(wsFails>=3||!token)startPolling();
    else setDot("off");
    if(token)setTimeout(connectWS,retry);
    retry=Math.min(retry*2,15000);
  };
  sock.onerror=function(){};
}
function startPolling(){
  setDot("poll");
  if(pollTimer)return;
  pollTimer=setInterval(function(){refresh();if(activeTab==="timers"||role==="stage")loadTimers()},2000);
}
// Running timers tick on the phone every second; nothing else polls once
// the socket is up.
setInterval(function(){
  if(!token||document.hidden)return;
  if(role==="stage"){tick();loadTimers()}
  else if(activeTab==="timers")loadTimers();
},1000);
tick();

init();
})();
</script>
</body>
</html>
"""#
}
