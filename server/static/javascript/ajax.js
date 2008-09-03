if( typeof XMLHttpRequest == "undefined" ) XMLHttpRequest = function() {
  try { return new ActiveXObject("Msxml2.XMLHTTP.6.0") } catch(e) {}
  try { return new ActiveXObject("Msxml2.XMLHTTP.3.0") } catch(e) {}
  try { return new ActiveXObject("Msxml2.XMLHTTP") } catch(e) {}
  try { return new ActiveXObject("Microsoft.XMLHTTP") } catch(e) {}
  throw new Error( "This browser does not support XMLHttpRequest." )
};

function ajax(url, vars, callbackFunction) {
  var request =  new XMLHttpRequest();
  request.open("POST", url, true);
  request.setRequestHeader("Content-Type",
                           "application/x-javascript;");
 
  request.onreadystatechange = function() {
    if (request.readyState == 4 && request.status == 200) {
      if (request.responseText) {
        callbackFunction(request.responseText);
      }
    }
  };
  request.send(vars);
  return request;
};

function $A(iterable) {
  if (!iterable) return [];
  if (iterable.toArray) return iterable.toArray();
  var length = iterable.length, results = new Array(length);
  while (length--) results[length] = iterable[length];
  return results;
};

Function.prototype.bind = function() {
  if (arguments.length < 2 && typeof arguments[0] == "undefined") return this;
  var __method = this, args = $A(arguments), object = args.shift();
  return function() {
    return __method.apply(object, args.concat($A(arguments)));
  }
};

Function.prototype.curry = function() {
  if (!arguments.length) return this;
  var __method = this, args = $A(arguments);
  return function() {
    return __method.apply(this, args.concat($A(arguments)));
  }
};

String.prototype.stripScripts = function() {
  return this.replace(new RegExp(YourSway.ScriptFragment, 'img'), '');
};

String.prototype.extractScripts = function() {
  var matchAll = new RegExp(YourSway.ScriptFragment, 'img');
  var matchOne = new RegExp(YourSway.ScriptFragment, 'im');
  return (this.match(matchAll) || []).map(function(scriptTag) {
    return (scriptTag.match(matchOne) || ['', ''])[1];
  });
};

String.prototype.evalScripts = function() {
  return this.extractScripts().map(function(script) { return eval(script) });
};

function $(id) {
	return document.getElementById(id);
}

var YourSway = {
  
  ScriptFragment: '<script[^>]*>([\\S\\s]*?)<\/script>'
  
};

// initial_timeout - milliseconds
// period - milliseconds
// requestor.start(success_callback, failure_callback) -> request_obj
// requestor.cancel(request_obj)
// handler(response_text)
YourSway.PeriodicExecutor = function(options) {
	this.last_request = null;
	this.last_request_id = 0;
	this.watchdog = null;
	this.timeout = options.timeout || 10000;
	this.period = options.period || 2000;
	this.start_request = options.requestor.start;
	this.cancel_request = options.requestor.cancel;
	this.result_handler = options.handler || function(text) {};
	window.setTimeout(this.initiate_request.bind(this, 0), options.initial_timeout || 100);
};

YourSway.PeriodicExecutor.prototype.initiate_request = function(id) {
	log("initiate_request " + id);
	if (id != this.last_request_id) return;
	this.cancel_current_request();
	
	this.last_request = this.start_request(this.success_callback.bind(this, id),
		this.failed_callback.bind(this, id));
	this.watchdog = window.setTimeout(this.watchdog_handler.bind(this), this.timeout);
};

YourSway.PeriodicExecutor.prototype.success_callback = function(id, text) {
	if (id != this.last_request_id) return;
	log("callback " + id);
	this.request_succeeded();
  this.result_handler(text);
};

YourSway.PeriodicExecutor.prototype.failed_callback = function(id) {
	if (id != this.last_request_id) return;
	log("error_callback " + id);
	this.request_failed();
};

YourSway.PeriodicExecutor.prototype.request_succeeded = function() {
	this.request_finished();
  // $('message').innerHTML = '';
};

YourSway.PeriodicExecutor.prototype.request_failed = function() {
	this.request_finished();
  // $('message').innerHTML = 'Unable to reach YourSway Builder...';
};

YourSway.PeriodicExecutor.prototype.request_finished = function() {
	if (this.watchdog) {
		window.clearTimeout(this.watchdog);
		this.watchdog = null;
	}
	this.last_request = null;
	this.schedule_request();
};

YourSway.PeriodicExecutor.prototype.watchdog_handler = function() {
	log("watchdog")
	this.request_failed();
};

YourSway.PeriodicExecutor.prototype.cancel_current_request = function() {
	if (this.last_request != null) {
		this.cancel_request(this.last_request);
		this.last_request = null;
	}
};

YourSway.PeriodicExecutor.prototype.schedule_request = function() {
	log("schedule_request");
	var id = ++this.last_request_id;
	window.setTimeout(this.initiate_request.bind(this, id), this.period);
};

YourSway.AjaxRequestor = function(url) {
  return {
    start: function(success, failed) {
      return ajax(url, "", function(text) {
        success(text.stripScripts());
        text.evalScripts();
      }, failed);
    },
    cancel: function(req) {
      req.abort();
    }
  };
}

YourSway.Response = {};

YourSway.Response.Ignore = function(text) {
};

YourSway.Response.UpdateDiv = function(id) {
  return function(text) {
    $(id).innerHTML = text;
  };
};

YourSway.Response.UpdateLogDiv = function(id) {
  return function(text) {
    var div = $(id);
    div.innerHTML = text;
    // window.setTimeout(function() {
      div.scrollTop = div.scrollHeight;
    // }, 150);
  };
};
// id, period, url, timeout
function periodically_update(options) {
  new YourSway.PeriodicExecutor({
    requestor: YourSway.AjaxRequestor(options.url),
    handler: YourSway.Response.UpdateLogDiv(options.id),
    period: options.period || 2000,
    timeout: options.timeout || 10000
  });
}

function log(msg) {
  l = $('log');
  if(l)
    l.innerHTML = msg + "\n" + l.innerHTML;
}

function reload_page() {
  window.location.href = window.location.href;
}
