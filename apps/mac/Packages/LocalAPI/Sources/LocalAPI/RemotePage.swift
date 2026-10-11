import Foundation

/// The phone/tablet remote: one self-contained page served at `/` and `/remote`.
/// The page itself needs no auth; every API call it makes carries the token.
public enum RemotePage {
    public static func html(serviceName: String) -> String {
        template.replacingOccurrences(of: "__SERVICE_NAME__", with: escape(serviceName))
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
<meta name="theme-color" content="#0b0d10">
<title>Remote</title>
<style>
:root{--bg:#0b0d10;--card:#171b21;--card2:#1f252d;--line:#2a313b;--text:#f2f5f8;--dim:#8b96a3;--accent:#3b82f6;--ok:#22c55e;--bad:#ef4444;--warn:#f59e0b}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;height:100%;background:var(--bg);color:var(--text);font:16px/1.35 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;touch-action:manipulation;-webkit-user-select:none;user-select:none;overscroll-behavior:none}
body{padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)}
#app{display:flex;flex-direction:column;height:100%;max-width:900px;margin:0 auto}
header{display:flex;align-items:center;gap:10px;padding:10px 14px;border-bottom:1px solid var(--line)}
#dot{width:12px;height:12px;border-radius:50%;background:var(--bad);flex:none}
#dot.on{background:var(--ok)}#dot.poll{background:var(--warn)}
#title{font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex:1}
#sub{color:var(--dim);font-size:13px}
nav{display:flex;gap:6px;padding:8px 14px}
nav button{flex:1;padding:10px;border-radius:10px;border:1px solid var(--line);background:var(--card);color:var(--dim);font-size:15px;font-weight:600}
nav button.act{background:var(--accent);color:#fff;border-color:var(--accent)}
main{flex:1;overflow-y:auto;-webkit-overflow-scrolling:touch;padding:6px 14px 20px}
.tab{display:none}.tab.act{display:block}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px;margin-bottom:10px}
.card .lab{color:var(--dim);font-size:12px;text-transform:uppercase;letter-spacing:.08em;margin-bottom:6px}
#cur{font-size:clamp(22px,5.5vw,34px);font-weight:700;min-height:2.6em;white-space:pre-wrap;word-break:break-word}
#nxt{font-size:clamp(16px,3.6vw,22px);color:#c3cbd5;min-height:1.4em;white-space:pre-wrap;word-break:break-word}
.row{display:flex;gap:10px;margin-bottom:10px}
button{font:inherit;color:var(--text);border:0;cursor:pointer}
.btn{flex:1;border-radius:14px;background:var(--card2);border:1px solid var(--line);padding:14px 8px;font-weight:600;transition:background .12s,transform .08s}
.btn.flash,.btn:active{background:var(--accent);transform:scale(.97)}
.big{font-size:clamp(26px,7vw,44px);font-weight:800;min-height:clamp(96px,22vh,170px)}
.big.next{background:#1d4ed8;border-color:#1d4ed8;flex:1.6}
.big.next.flash,.big.next:active{background:#60a5fa}
.clr{color:#fecaca;min-height:56px;font-size:15px}
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
#toast{position:fixed;left:50%;bottom:calc(16px + env(safe-area-inset-bottom));transform:translateX(-50%);background:#7f1d1d;color:#fff;padding:10px 16px;border-radius:10px;opacity:0;pointer-events:none;transition:opacity .2s;max-width:90%;z-index:9}
#toast.show{opacity:1}
#gate{display:none;padding:30px 20px;max-width:480px;margin:0 auto}
#gate input{width:100%;padding:14px;font-size:17px;border-radius:12px;border:1px solid var(--line);background:var(--card);color:var(--text);margin:14px 0;-webkit-user-select:text;user-select:text}
#gate p{color:var(--dim)}
.empty{color:var(--dim);text-align:center;padding:24px}
</style>
</head>
<body data-service="__SERVICE_NAME__">
<div id="gate">
  <h2>Enter access code</h2>
  <p>Paste the access code (API token) from the Mac app's Settings &rsaquo; Network &amp; API.</p>
  <input id="tokenIn" type="text" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="Access code">
  <button class="btn" id="tokenGo" style="width:100%">Connect</button>
  <p id="gateErr" style="color:var(--bad)"></p>
</div>
<div id="app" style="display:none">
  <header><span id="dot"></span><div style="flex:1;min-width:0"><div id="title"></div><div id="sub"></div></div></header>
  <nav>
    <button data-tab="show" class="act">Show</button>
    <button data-tab="slides">Slides</button>
    <button data-tab="timers">Timers</button>
    <button data-tab="macros">Macros</button>
  </nav>
  <main>
    <section class="tab act" id="tab-show">
      <div class="card"><div class="lab">Now</div><div id="cur">&mdash;</div></div>
      <div class="card"><div class="lab">Next</div><div id="nxt">&mdash;</div></div>
      <div class="row">
        <button class="btn big" id="prev">&#9664; PREV</button>
        <button class="btn big next" id="next">NEXT &#9654;</button>
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
  </main>
</div>
<div id="toast"></div>
<script>
(function(){
"use strict";
var KEY="remoteToken", token="", status=null, ws=null, pollTimer=null, wsFails=0, retry=1000, deck=null, deckId=null, lastFire=0, activeTab="show";
var $=function(id){return document.getElementById(id)};
var serviceName=document.body.getAttribute("data-service")||"";

function store(k,v){try{if(v===null)localStorage.removeItem(k);else if(v!==undefined)localStorage.setItem(k,v);return localStorage.getItem(k)}catch(e){return null}}
function init(){
  var q=new URLSearchParams(location.search), t=q.get("token");
  if(t){store(KEY,t);q.delete("token");var s=q.toString();history.replaceState(null,"",location.pathname+(s?"?"+s:"")+location.hash)}
  token=store(KEY)||"";
  if(token)start();else gate();
}
function gate(msg){
  stop();$("app").style.display="none";$("gate").style.display="block";$("gateErr").textContent=msg||"";
}
$("tokenGo").onclick=function(){var v=$("tokenIn").value.trim();if(!v)return;token=v;store(KEY,v);$("gate").style.display="none";start()};
function start(){
  $("gate").style.display="none";$("app").style.display="flex";
  $("title").textContent=serviceName;
  refresh();connectWS();loadTimers();loadMacros();
}
function stop(){
  if(ws){try{ws.onclose=null;ws.close()}catch(e){}ws=null}
  if(pollTimer){clearInterval(pollTimer);pollTimer=null}
}
function toast(m){var e=$("toast");e.textContent=m;e.className="show";clearTimeout(toast.t);toast.t=setTimeout(function(){e.className=""},2600)}

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
function setDot(m){var d=$("dot");d.className=m==="ws"?"on":m==="poll"?"poll":"";}
function render(){
  var s=status||{}, live=s.liveSlide||null;
  var name=(live&&live.presentationName)||(s.service&&s.service.name)||"";
  $("title").textContent=serviceName+(name?" • "+name:"");
  var pos=s.position;
  $("sub").textContent=pos&&pos.currentItemName?(pos.currentItemName+(pos.nextItemName?"  →  "+pos.nextItemName:"")):(live&&live.slideCount?("Slide "+((live.slideIndex||0)+1)+" of "+live.slideCount):"");
  $("cur").textContent=live?(live.text||live.slideName||"(no text)"):"Nothing live";
  var nt=(s.nextSlide&&s.nextSlide.text)||s.nextSlideText;
  $("nxt").textContent=nt||"—";
  if(live&&live.presentationId&&live.presentationId!==deckId)loadDeck(live.presentationId);
  markLive();
}
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
  var els=document.querySelectorAll(".slide");
  for(var i=0;i<els.length;i++)els[i].classList.toggle("live",els[i].getAttribute("data-id")===id);
}

function loadTimers(){
  api("GET","/v1/timers").then(drawTimers).catch(function(){});
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
    [["play",t.running?"⏸":"▶","play"],["pause","Pause","pause"],["reset","Reset","reset"]].forEach(function(a){
      if(a[0]==="play"&&t.running)return;
      if(a[0]==="pause"&&!t.running)return;
      var b=document.createElement("button");b.className="btn";b.textContent=a[0]==="play"?"Start":a[1];
      b.onclick=function(){if(!guard())return;flash(b);act("POST","/v1/timers/"+encodeURIComponent(t.id)+"/"+a[2],undefined,function(){setTimeout(loadTimers,250)})};
      d.appendChild(b);
    });
    el.appendChild(d);
  });
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
var clears=document.querySelectorAll("[data-clear]");
for(var i=0;i<clears.length;i++)clears[i].onclick=function(){if(!guard())return;flash(this);act("POST","/v1/show/clear",{"function":this.getAttribute("data-clear")},function(){if(!ws)refresh()})};
$("clearAll").onclick=function(){if(!guard())return;flash(this);act("POST","/v1/show/clear-all",undefined,function(){if(!ws)refresh()})};

var tabs=document.querySelectorAll("nav button");
for(var j=0;j<tabs.length;j++)tabs[j].onclick=function(){
  activeTab=this.getAttribute("data-tab");
  for(var k=0;k<tabs.length;k++)tabs[k].classList.toggle("act",tabs[k]===this);
  var secs=document.querySelectorAll(".tab");
  for(var m=0;m<secs.length;m++)secs[m].classList.toggle("act",secs[m].id==="tab-"+activeTab);
  if(activeTab==="timers")loadTimers();
  if(activeTab==="macros")loadMacros();
};

document.addEventListener("keydown",function(e){
  if(!token||e.target.tagName==="INPUT")return;
  if(e.key==="ArrowRight"||e.key==="ArrowDown"||e.key===" "||e.key==="PageDown"){e.preventDefault();advance(1,$("next"))}
  else if(e.key==="ArrowLeft"||e.key==="ArrowUp"||e.key==="PageUp"){e.preventDefault();advance(-1,$("prev"))}
});
var lastTouch=0;
document.addEventListener("touchend",function(e){var n=Date.now();if(n-lastTouch<300)e.preventDefault();lastTouch=n},{passive:false});
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
    else if(m.topic==="library"){loadMacros();deckId=null;refresh()}
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
  pollTimer=setInterval(function(){refresh();if(activeTab==="timers")loadTimers()},2000);
}
setInterval(function(){if(activeTab==="timers"&&token)loadTimers()},1000);

init();
})();
</script>
</body>
</html>
"""#
}
