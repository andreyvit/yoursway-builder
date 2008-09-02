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
}

function $A(iterable) {
  if (!iterable) return [];
  if (iterable.toArray) return iterable.toArray();
  var length = iterable.length, results = new Array(length);
  while (length--) results[length] = iterable[length];
  return results;
}

Function.prototype.bind = function() {
  if (arguments.length < 2 && typeof arguments[0] == "undefined") return this;
  var __method = this, args = $A(arguments), object = args.shift();
  return function() {
    return __method.apply(object, args.concat($A(arguments)));
  }
}

Function.prototype.curry = function() {
  if (!arguments.length) return this;
  var __method = this, args = $A(arguments);
  return function() {
    return __method.apply(this, args.concat($A(arguments)));
  }
}

function $(id) {
	return document.getElementById(id);
}

var YourSway = {};

// initial_timeout
// period
// start_request
// cancel_request
YourSway.PeriodicExecutor = function(start, cancel, options) {
	this.last_request = null;
	this.last_request_id = 0;
	this.watchdog = null;
	this.options = options;
	this.options.start_request = start;
	this.options.cancel_request = cancel;
	window.setTimeout(this.initiate_request.bind(this, 0), this.options.initial_timeout || 100);
}

YourSway.PeriodicExecutor.prototype.initiate_request = function(id) {
	log("initiate_request " + id);
	if (id != this.last_request_id) return;
	this.cancel_current_request();
	
	this.last_request = this.options.start_request(this.success_callback.bind(this, id),
		this.failed_callback.bind(this, id));
	this.watchdog = window.setTimeout(this.watchdog_handler.bind(this), this.options.timeout || 10000);
}

YourSway.PeriodicExecutor.prototype.success_callback = function(id) {
	if (id != this.last_request_id) return;
	log("callback " + id);
	this.request_succeeded();
}

YourSway.PeriodicExecutor.prototype.failed_callback = function(id) {
	if (id != this.last_request_id) return;
	log("error_callback " + id);
	this.request_failed();
}

YourSway.PeriodicExecutor.prototype.request_succeeded = function() {
	this.request_finished();
  // $('message').innerHTML = '';
}

YourSway.PeriodicExecutor.prototype.request_failed = function() {
	this.request_finished();
  // $('message').innerHTML = 'Unable to reach YourSway Builder...';
}

YourSway.PeriodicExecutor.prototype.request_finished = function() {
	if (this.watchdog) {
		window.clearTimeout(this.watchdog);
		this.watchdog = null;
	}
	this.last_request = null;
	this.schedule_request();
}

YourSway.PeriodicExecutor.prototype.watchdog_handler = function() {
	log("watchdog")
	this.request_failed();
}

YourSway.PeriodicExecutor.prototype.cancel_current_request = function() {
	if (this.last_request != null) {
		this.options.cancel_request(this.last_request);
		this.last_request = null;
	}
}

YourSway.PeriodicExecutor.prototype.schedule_request = function() {
	log("schedule_request");
	var id = ++this.last_request_id;
	window.setTimeout(this.initiate_request.bind(this, id), this.options.period || 2000);
}

start_ajax_update_request = function(url, id, success, failed) {
  return ajax(url, "", function(text) {
    success();
    $(id).innerHTML = text;
  }, failed);
}

start_ajax_eval_request = function(url, id, success, failed) {
  return ajax(url, "", function(text) {
    success();
    eval(text);
  }, failed);
}

cancel_ajax_request = function(req) {
  req.abort();
}

// id, period, url, timeout
function periodically_update(options) {
  new YourSway.PeriodicExecutor(start_ajax_update_request.curry(options.url, options.id),
    cancel_ajax_request, { period: options.period || 2000, timeout: options.timeout || 10000 });
}

function log(msg) {
  l = $('log');
  if(l)
    l.innerHTML = msg + "\n" + l.innerHTML;
}
