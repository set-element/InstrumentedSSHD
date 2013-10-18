# 07/28/2012: Scott Campbell
#
# Core analyzer for analyzing basic sshd
# The utility provided by this policy is *logging* in nature.  Authentication rules,
#  local policy re. hostile commands and content, key analysis etc are all rolled
#  into their respective policy files.
#
# In addition, most of the utility functions are maintained in this file as well
#
# This version has been modified so that all output is run through the LOG:: output
#   framework since in a clustering environment you do not get to make the friendly
#   human readable output which makes for such good reading ...
#

@load sshd_const
@load user_core

module SSHD_CORE;

export {
	## NOTE: The LOG functionality is put in for machine consumption rather than human consumption.
	##         Regular logging is optimized forreading, while LOG is set up for elasticsearch.
	##       Thusly the fields defined are those best used for database like queries
	##         Include a switch for on/off - move to sshd_elasticsearch ...
	##
	## The SSHD_CORE logging stream identifier
	redef enum Log::ID += { LOG };

	## Record type which contains column fields for the isshd log
	type Info: record {
		
		## session start time
		ts_start:	time	&log;
		## session current time: note this is not necessisarily current time
		##  since the logs might be old and time is not synced to log reader input
		ts:		time	&log;
		## key for session identification
		key:		string	&log;
		## connection 4-tuple
		id:		conn_id	&log;
		## user assosciated with session
		uid:		string	&log &default="UID_UNKNOWN";
		## current channel number
		channel: 	count	&log &default = 0;
		## current channel type	
		channel_t:	string	&log &default="D_UNKNOWN";
		## server host name
		host:		string	&log &default="HOST_UNKNOWN";
		## event name
		name:		string	&log &default="EVENT_UNKNOWN";
		## external host: host attached to forward
		##  tunnel or proxy
		ext_host:       string  &log &default="FWDHOST_UNKNOWN";
		## external port: port attached to ext_host address
		ext_port:       string  &log &default="FWDPORT_UNKNOWN";
		## event data
		data:		string	&log &default="DATA_UNKNOWN";
	};

	redef enum Notice::Type += {
		SSHD_Heartbeat,
		SSHD_NewHeartbeat,
		SSHD_Start,
		SSHD_Exit,
		SSHD_PasswdThresh,
	};

	# global sshd index for sessions
	global s_index: count = 0;
	
	global c_record_clean: function(t: table[count] of int, idx:count) : interval;

	######################################################################################
	#  data structs and tables
	######################################################################################
	type client_record: record {
		id: conn_id;				# generated by function, handy to have
		uid: string &default = "UNKNOWN";	# value reset by login
		auth_type: string &default = "UNKNOWN";	# value reset by login
		auth_state: count &default=1;		# used to track logins
		suspicous_count: count &default = 0;	# running total for suspicous commands
		#client_tag: count &default = 0;		# unique id
		start_time: time;			# 
		passwd_skip: count &default = 0;	# how many times passwd entry skipped

		# table of channel types - may need to reinsert state 
		channel_type: table[count] of string;
		s_commands: set[string];		# list of suspicous commands entered
		log_id: string &default = "UNSET";	# tag for logging index; Q: usability vs one less field
	};

	type server_record: record {
		# put in a rate monitor here as well ..	
		c_records: table[count] of client_record;	# this is a table of client_record types
		current_clients: count;				#
		start_time: time;				#
		heartbeat_state: count &default=0;		#
		heartbeat_last: double;				#
	};

	global s_record_clean: function(t: table[string] of server_record, idx:string) : interval;
	# this is a table holding all the known server instances
	global s_records: table[string] of server_record  &persistent &expire_func=s_record_clean &write_expire = 24 hr;

	# When a subsystem is instantiated, the process loses the cid data which is an 
	#  issue in tracking the behavior.  This table keeps track of the cid as a function
	#  of the ppid and sid - it will be set when the forking settles down post privsep.
	global cid_lookup: table[string, int] of count;

	# in order to keep track of usage, we have a table which records which events are used
	global sshd_auditor: table[string] of count;

	# table holding data relevant to logging info
	global s_logging: table[string] of Info;

	# functions for testing client and server records
	global test_sid: function(sid: string) : server_record;
	global test_cid: function(sid: string, cid: count) : client_record;
	# function for auditing usage
	global sshd_audit: function(call: string);
	# function to register and look up cid
	global lookup_cid: function(sid: string,ppid: int) : count;
	global register_cid: function(sid: string, cid: count, ppid: int) : count;
	global print_sid: function(sid: string) : string;
	# print channel data
	global print_channel: function(CR: client_record, channel: count) : string;
	## -- Functions for logging work
	global log_session_register: function(CR: client_record) : count;
	# update interactive data
	global log_session_update_event: function(CR: client_record, etime: time, e: string, s_data: string) : count;
	
	global log_server_session: function(SR: server_record, etime: time, e: string, s_data: string) : count;
	global log_update_uid: function(CR: client_record, uid: string) : count;
	global log_update_channel: function(CR: client_record, channel: count) : count;
	global log_update_host: function(CR: client_record, host: string) : count;
	global log_update_forward: function(CR: client_record, forward_host: string, h_port: port) : count;

	# More utility functions, exported for the older policy cluster port
	global remove_cid: function(sid:string, cid:count) : int;
	global create_connection: function(s_ip: addr, s_port: port, r_ip: addr, r_port: port, ts: time): conn_id;
	global save_cid: function(sid: string, cid: count, cr: client_record);
	global get_info_key: function(CR: client_record) : string;

	######################################################################################
	#  configuration
	#
	######################################################################################

	# suspicous commands 
	global notify_suspicous_command = T &redef;

	global suspicous_threshold: count = 5 &redef;
	global suspicous_command_list = 
		/^who/
		| /^rpcinfo/
	&redef;

	# this set of commands should be alarmed on when executed
	#  remotely
	global alarm_remote_exec =
		/sh -i/
		| /bash -i/
	&redef;

	const user_white_list =
		/^billybob$/
	&redef;

	# heartbeat timeout interval ...
	const heartbeat_timeout = 300 sec &redef;

	# password skip alarm threshold
	const password_threshold = 10 &redef;

	const HB_INIT = 0;
	const HB_OK = 1;
	const HB_ERROR = 2;

} # end of export

######################################################################################
#  external values
######################################################################################

redef Communication::nodes += {
	["sshd2"] = [$host = 127.0.0.1, $events = /.*/, $connect=F, $ssl=F],
};

######################################################################################
#  functions 
######################################################################################

function create_connection(s_ip: addr, s_port: port, r_ip: addr, r_port: port, ts: time): conn_id
{
	local id: conn_id;

	id$orig_h = s_ip;
	id$orig_p = s_port;
	id$resp_h = r_ip;
	id$resp_p = r_port;

	return id;
}

function sshd_audit(call: string)
{
	# look and see if this is a new call
	if ( call !in sshd_auditor ) {
		local t_call: string = call;
		sshd_auditor[t_call] = 0;
	}

	# increment the name counter
	++sshd_auditor[call];

	return;
}

function test_sid(sid: string): server_record
{
	# Test to see if server record exists.  If so, return it
	#   else create a new one.
	local t_server_record: server_record;

	if ( sid ! in s_records ) {
		# this is an unknown instance so we
		# create something new
		t_server_record$current_clients = 0;
		t_server_record$start_time = network_time();
		#t_server_record$active = 1;

		s_records[sid] = t_server_record;
	}
	else {
		t_server_record = s_records[sid];
	}
	
	return t_server_record;
}

function test_cid(sid: string, cid: count): client_record
{
	# Since every cid must have a sid, first test for it.
	# When created, it will be nearly empty - we will fill it in later
	#   via the calling event.
	local t_client_rec: client_record;

	# first check the sid
	local t_server_rec = test_sid(sid);

	if ( cid !in t_server_rec$c_records ) {

		# create a new rec and insert it into the table
		# first increment the client session identifier
		#++s_index;
		#t_client_rec$client_tag = s_index;

		# this can be reset later, but fill in the time with a sane value
		t_client_rec$start_time = network_time();

		# create a blank table for channel state
		local t_cs:table[count] of string;
		t_client_rec$channel_type = t_cs;

		# now fill in the blank connection values
		t_client_rec$id$orig_h = 0.0.0.0;
		t_client_rec$id$orig_p = 0/tcp;
		t_client_rec$id$resp_h = 0.0.0.0;
		t_client_rec$id$resp_p = 0/tcp;

		# there might be a better way to go about doing this
		# but this will ensure that the client_record is also 
		#  registered in the logging framework
		log_session_register(t_client_rec);

		t_server_rec$c_records[cid] = t_client_rec;
	}
	else {
		t_client_rec = t_server_rec$c_records[cid];
	}

	return t_client_rec;
}

# insert a cient record back into the appropriate data structure
#
function save_cid(sid: string, cid: count, cr: client_record)
{
	if ( sid in s_records ) {
		s_records[sid]$c_records[cid] = cr;
	}
}

function remove_cid(sid:string, cid:count) : int
{
	local ret: int = 1;

	if ( sid in s_records ) 

		if ( cid in s_records[sid]$c_records ) {

			# now that we have a record, start removing things
			local c: count;

			# remove the client record channels 
			for ( c in s_records[sid]$c_records[cid]$channel_type )
				delete s_records[sid]$c_records[cid]$channel_type[c];

			# get rid of the logging data record
			if ( s_records[sid]$c_records[cid]$log_id in s_logging )
				delete s_logging[s_records[sid]$c_records[cid]$log_id];

			# finally get rid of the client record itself
			delete s_records[sid]$c_records[cid];
			ret = 0;
		}
	return ret;
}

# calls remove_cid() 
function remove_sid(sid:string) : int
	{
	local ret: int = 1;
	local t_cid: count;

	if ( sid in s_records ) {

		for ( t_cid in s_records[sid]$c_records )
			remove_cid(sid, t_cid);

		delete s_records[sid];
		ret = 0;
	}

	return ret;
	}

function s_record_clean(t: table[string] of server_record, idx:string) : interval
	{
	remove_sid(idx);
	return 0 secs;
	}

function c_record_clean(t: table[count] of int, idx:count) : interval
	{
	# for the time being, see if the s-record_clean will take care of any issues
	# if not, just add another field to the client_record holding the sid
	#remove_cid(idx);
	return 0 secs;
	}

function print_sid(sid: string) : string
	{
	# sid is of the form "hostname hostid port"
	local ret_val = "00000";
	local split_on_space = split(sid, /:/);

	if ( |split_on_space| > 1 )
		ret_val = split_on_space[2];

	return ret_val;
	}

function print_channel(CR: client_record, channel: count) : string
	{
	# if the channel value exists, return it, else set the 
	#  value to ret_value and set it.
	local ret_value: string = "UNKNOWN";

	if ( channel in CR$channel_type )
		ret_value = CR$channel_type[channel];
	else
		CR$channel_type[channel] = ret_value;

	return ret_value;
	}

function lookup_cid(sid: string, ppid: int) : count
	{
	local ret: count = 0;
	local split_cln = split(sid, /:/);
	local t_sid = fmt("%s:%s", split_cln[2], split_cln[3]);

	if ( [t_sid,ppid] in cid_lookup ) {
		ret = cid_lookup[t_sid,ppid];
		}

	return ret;
	}

function register_cid(sid: string, cid: count, ppid: int) : count
	{
	local ret: count = 0;
	local split_cln = split(sid, /:/);
	local t_sid = fmt("%s:%s", split_cln[2], split_cln[3]);

	if ( [t_sid,ppid] !in cid_lookup ) {
		cid_lookup[t_sid,ppid] = cid;
		}
	else
		ret = 1;
 
	return ret;
	}

function log_session_register(CR: client_record) : count
{
	local session: Info;
	local t_id: conn_id;

	local key = unique_id("");
	CR$log_id = key;

	session$ts_start = CR$start_time;
	session$ts = CR$start_time;
	t_id$orig_h = CR$id$orig_h;
	t_id$orig_p = CR$id$orig_p;
	t_id$resp_h = CR$id$resp_h;
	t_id$resp_p = CR$id$resp_p;
	session$id = t_id;
	session$key = key;
	
	s_logging[key] = session;
	return 0;
}

function log_server_session(SR: server_record, etime: time, e: string, s_data: string) : count
{
	local t_Info: Info;
	local ret: count = 0;

	t_Info$ts = etime;
	t_Info$name = e;
	t_Info$data = s_data;

	# and print the results
	Log::write(LOG, t_Info);

	return ret;
}

function log_session_update_event(CR: client_record, etime: time, e: string, s_data: string) : count
{
	local t_Info: Info;
	local ret: count = 0;

	# take client_record, event name and event data, fill in struct, and print out
	if ( strcmp(CR$log_id,"UNSET") == 0  ) {
		# the client session has not been registered with the CR, fix that
		log_session_register(CR);
	}

	# now update the event and data
	if ( CR$log_id in s_logging )
		t_Info = s_logging[CR$log_id];
	else {
		local err_msg = fmt("     updating session event - skip %s - not found", CR$log_id);
		Reporter::error(err_msg);
		log_session_register(CR);
		return ret;
		}

	t_Info$ts = etime;
	t_Info$name = e;
	t_Info$data = s_data;

	# and print the results
	Log::write(LOG, t_Info);

	s_logging[CR$log_id] = t_Info;
	return ret;	
}

function log_update_uid(CR: client_record, uid: string) : count
{
	local t_Info: Info;
	local ret: count = 0;

	# take client_record, event name and event data, fill in struct, and print out
	if ( strcmp(CR$log_id,"UNSET") == 0  ) {
		# the client session has not been registered with the CR, fix that
		log_session_register(CR);
	}

	# now update the event and data
	if ( CR$log_id in s_logging )
		t_Info = s_logging[CR$log_id];
	else 
		return ret;

	t_Info$uid = uid;

	s_logging[CR$log_id] = t_Info;
	ret = 1;
	return ret;	
}

function log_update_channel(CR: client_record, channel: count) : count
{
	local t_Info: Info;
	local ret: count = 0;

	# take client_record, event name and event data, fill in struct, and print out
	if ( strcmp(CR$log_id,"UNSET") == 0  ) {
		# the client session has not been registered with the CR, fix that
		log_session_register(CR);
	}

	# now update the event and data
	if ( CR$log_id in s_logging )
		t_Info = s_logging[CR$log_id];
	else 
		return ret;

	t_Info$channel = channel;
	t_Info$channel_t = CR$channel_type[channel];

	s_logging[CR$log_id] = t_Info;

	ret = 1;
	return ret;	
}

function log_update_forward(CR: client_record, forward_host: string, h_port: port) : count
{
	local t_Info: Info;
	local ret: count = 0;

	# take client_record, event name and event data, fill in struct, and print out
	if ( strcmp(CR$log_id,"UNSET") == 0  ) {
		# the client session has not been registered with the CR, fix that
		log_session_register(CR);
		}

	# now update the event and data
	if ( CR$log_id in s_logging )
		t_Info = s_logging[CR$log_id];
	else 
		return ret;

	t_Info$ext_host = forward_host;
	t_Info$ext_port = fmt("%s",h_port);

	s_logging[CR$log_id] = t_Info;
	ret = 1;
	return ret;	
}

function log_update_host(CR: client_record, host: string) : count
{
	local t_Info: Info;
	local ret: count = 0;
	# take client_record, event name and event data, fill in struct, and print out
	if ( strcmp(CR$log_id,"UNSET") == 0  ) {
		# the client session has not been registered with the CR, fix that
		log_session_register(CR);
		}

	# now update the event and data
	if ( CR$log_id in s_logging )
		t_Info = s_logging[CR$log_id];
	else 
		return ret;

	t_Info$host = host;

	# since we are here, make sure that this is up to date as well ...
	t_Info$id$orig_h = CR$id$orig_h;
	t_Info$id$orig_p = CR$id$orig_p;
	t_Info$id$resp_h = CR$id$resp_h;
	t_Info$id$resp_p = CR$id$resp_p;

	s_logging[CR$log_id] = t_Info;
	ret = 1;
	return ret;	
}

function get_info_key(CR: client_record) : string
{
	local ret_val: string = "UNKNOWN_KEY";
	local t_Info: Info;

	# take client_record, event name and event data, fill in struct, and print out
	if ( strcmp(CR$log_id,"UNSET") == 0  ) {
		# the client session has not been registered with the CR, fix that
		log_session_register(CR);
	}

	# now update the event and data
	if ( CR$log_id in s_logging )
		t_Info = s_logging[CR$log_id];
	else 
		return ret_val;

	return t_Info$key;
}

######################################################################################
#  events
######################################################################################

# Rather than having a bunch of events for every type of auth/meth/state, we just
#  wrap it all up into one big event.  
# Currently authmesg: {Postponed, Accepted, Failed}
# 	method: typically password, publickey, hostbased, keyboard-interactive/pam
#
# This will be designed to work with the syslog analyzer code as well as with any other
#   simple user-id based authentication schemas.
#
event auth_info_3(ts: time, version: string, sid: string, cid: count, authmsg: string, uid: string, meth: string, s_addr: addr, s_port: port, r_addr: addr, r_port: port)
{
	local CR:client_record = test_cid(sid,cid);
	local SR:server_record = test_sid(sid);

	# fill in a few additional records inthe client and server records
	CR$id = create_connection(s_addr, s_port, r_addr, r_port, ts);
	CR$uid = uid;
	CR$auth_type = meth;
	CR$start_time = ts;

	++SR$current_clients;

	SR$c_records[cid] = CR;
	s_records[sid] = SR;

	local s_data = fmt("AUTH %s %s %s %s:%s > %s:%s", authmsg, uid, meth, s_addr, s_port, r_addr, r_port);

	# log data
	log_update_uid(CR,uid);
	log_session_update_event(CR, ts, "AUTH_INFO_3", s_data); 

	# this is for the generation of the USER_CORE::auth_transaction_token token
	#  which duplicates most of the info 
	local t_key = get_info_key(CR);
	
	event USER_CORE::auth_transaction(ts, CR$log_id, CR$id, uid, print_sid(sid), "isshd", "authentication", authmsg, meth, t_key);
} 


event auth_invalid_user_3(ts: time, version: string, sid: string, cid: count, uid: string)
{
	# first log this, then (when implemented) pass into the authentication module
	local CR:client_record = test_cid(sid,cid);

	local s_data = fmt("%s:%s > %s @ %s:%s",
		CR$id$orig_h, CR$id$orig_p, CR$id$resp_h, CR$id$resp_p, uid);

	log_update_uid(CR,uid);
	log_session_update_event(CR, ts, "AUTH_INVALID_USER_3", s_data); 
}


event auth_key_fingerprint_3(ts: time, version: string, sid: string, cid: count, fingerprint: string, key_type: string)
{
	local CR:client_record = test_cid(sid,cid);

	local s_data = fmt("%s type %s", fingerprint, key_type);
	
	log_session_update_event(CR, ts, "AUTH_KEY_FINGERPRINT_3", s_data); 

	# this is for the generation of the USER_CORE::auth_transaction_token token
	# create a map for ses-key <-> fingerprint
	local t_key = get_info_key(CR);
	event USER_CORE::auth_transaction_token(CR$uid, t_key, fingerprint);
}

event auth_pass_attempt_3(ts: time, version: string, sid: string, cid: count, uid: string, password: string)
{
	# previously this would only get called if the sshd has been configured with the 
	#  --with-passwdrec option set
	# now if the option has been set you will get the password, else you will be delivered 
	# a hash of the passwod.  Since the hash might be cleaned up a bit by the URI decoding,
	# the MD5 is taken of the total.
	#
	local CR:client_record = test_cid(sid,cid);

	local s_data = fmt("%s",password);	

	log_session_update_event(CR, ts, "AUTH_PASS_ATTEMPT_3", s_data); 

	# test to see if the uid has already been assigned or is 'UID_UNKNOWN'
	if ( CR$uid == "UID_UNKNOWN" )
		log_update_uid(CR,uid);
}

event channel_data_client_3(ts: time, version: string, sid: string, cid: count, channel:count, data:string)
{
	# general event for client data from a typical login shell
	local CR:client_record = test_cid(sid,cid);

	log_session_update_event(CR, ts, "CHANNEL_DATA_CLIENT_3", data); 
}

event channel_data_server_3(ts: time, version: string, sid: string, cid: count, channel:count, data:string)
{
	# general event for client data from a typical login shell
	local CR:client_record = test_cid(sid,cid);

	log_session_update_event(CR, ts, "CHANNEL_DATA_SERVER_3", data); 
}

event channel_data_server_sum_3(ts: time, version: string, sid: string, cid: count, channel: count, bytes_skip: count)
{
	# general event for client data from a typical login shell
	local CR:client_record = test_cid(sid,cid);

	local s_data = fmt("%s %s %s",  channel,print_channel(CR,channel), bytes_skip);
	log_session_update_event(CR, ts, "CHANNEL_DATA_SERVER_SUM_3", s_data);
}

event channel_free_3(ts: time, version: string, sid: string, cid: count,channel: count, name: string)
{
	# channel free event - pass back name and number
	local CR:client_record = test_cid(sid,cid);

	local s_data = fmt("%s %s",  channel,print_channel(CR,channel));

	log_session_update_event(CR, ts, "CHANNEL_FREE_3", s_data);
}

event channel_new_3(ts: time, version: string, sid: string, cid: count, found: count, ctype: count, name: string)
{
	# found: channel id
	# type: channel type including some state info, defined by ints
	# name: remote name as provided unstructured text

	local CR:client_record = test_cid(sid,cid);

	# if the value exists, throw a weird and run over it
	CR$channel_type[found] = to_lower(name);

	local s_data = fmt("%s %s %s", found, print_channel(CR,found), name);

	log_update_channel(CR,found);
	log_session_update_event(CR, ts, "CHANNEL_NEW_3", s_data);

}

event channel_notty_analysis_disable_3(ts: time, version: string, sid: string, cid: count, channel: count, byte_skip: int, byte_sent: int)
{
	# Record NOTTY_DATA_SAMPLE bytes regardless of the state of the
	#  test.  After ratio print/noprint exceeds NOTTY_BIN_RATIO.
	# This report on the results.

	local CR:client_record = test_cid(sid,cid);

	local s_data = fmt("%s %s", byte_skip, byte_sent);
	log_session_update_event(CR, ts, "CHANNEL_NOTTY_ANALYSIS_DISABLE_3", s_data);
}

event channel_notty_client_data_3(ts: time, version: string, sid: string, cid: count, channel: count, data: string)
{
	# client data via non-tty means ...

	local CR:client_record = test_cid(sid,cid);
	log_session_update_event(CR, ts, "CHANNEL_NOTTY_CLIENT_DATA_3", data);
}

event channel_notty_server_data_3(ts: time, version: string, sid: string, cid: count, channel: count, data: string)
{
	# server data via non-tty means ...

	local CR:client_record = test_cid(sid,cid);
	log_session_update_event(CR, ts, "CHANNEL_NOTTY_SERVER_DATA_3", data);
}

event channel_pass_skip_3(ts: time, version: string, sid: string, cid: count, channel: count)
{
	# Keep track of the number of times a data line is skipped
	#  in order to keep people from exploiting the password skip
	#  feature.

	local CR:client_record = test_cid(sid,cid);

	if ( ++CR$passwd_skip == password_threshold ) {

		NOTICE([$note=SSHD_PasswdThresh,
			$msg=fmt("SKIP: %s %s %s-%s %s %s %s @ %s -> %s:%s",
				password_threshold, CR$log_id, channel, print_channel(CR,channel), sid, cid, CR$uid, 
				CR$id$orig_h, CR$id$resp_h, CR$id$resp_p )]);
	}
	
	local s_data = fmt("%s %s",  channel,print_channel(CR,channel));

	log_session_update_event(CR, ts, "CHANNEL_PASS_SKIP_3", s_data);

	# update client record
	s_records[sid]$c_records[cid]$passwd_skip = CR$passwd_skip;
}

event channel_port_open_3(ts: time, version: string, sid: string, cid: count, channel: count, rtype: string, l_port: port, path: string, h_port: port, rem_host: string, rem_port: port)
{
	# rtype: type of port open { direct-tcpip, dynamic-tcpip, forwarded-tcpip }
	# l_port: port being listened for forwards
	# path: path for unix domain sockets, or host name for forwards 
	# h_port: remote port to connect for forwards
	# rem_host: remote IP addr
	# rep_port: remote port

	local CR:client_record = test_cid(sid,cid);

	local s_data = fmt("listen port %s for %s %s:%s -> %s:%s",  
		rtype, l_port, rem_host, rem_port, path, h_port);

	log_session_update_event(CR, ts, "CHANNEL_PORT_OPEN_3", s_data);
}
event channel_portfwd_req_3(ts: time, version: string, sid: string, cid: count, channel:count, host: string, fwd_port: count)
{
	# This is called after receiving CHANNEL_FORWARDING_REQUEST.  This initates
	#  listening for the port, and sends back a success reply (or disconnect
	#  message if there was an error).

	local CR:client_record = test_cid(sid,cid);

	local s_data = fmt("%s:%s", host, fwd_port);
	log_session_update_event(CR, ts, "CHANNEL_PORTFWD_REQ_3", s_data);
}

event channel_post_fwd_listener_3(ts: time, version: string, sid: string, cid: count, channel: count, l_port: port, path: string, h_port: port, rtype: string)
{
	# This socket is listening for connections to a forwarded TCP/IP port.
	#
	# rtype: type of port open { direct-tcpip, dynamic-tcpip, forwarded-tcpip }
	# l_port: port being listened for forwards
	# h_port: remote port to connect for forwards

	local CR:client_record = test_cid(sid,cid);

	local s_data = fmt("%s %s -> %s:%s", rtype, l_port, path, h_port);
	log_session_update_event(CR, ts, "CHANNEL_POST_FWD_LISTENER_3", s_data);
}

event channel_set_fwd_listener_3(ts: time, version: string, sid: string, cid: count, channel: count, c_type: count, wildcard: count, forward_host: string, l_port: port, h_port: port)
{
	# c_type: channel type - see const policy for conversion table and function
	# wildcard: 0=no wildcard, 1=
	#	 "0.0.0.0"               -> wildcard v4/v6 if SSH_OLD_FORWARD_ADDR
	# 	 "" (empty string), "*"  -> wildcard v4/v6
	# 
	# forward_host: host to forward to
	# l_port: port being listened for forwards 
	# h_port: remote port to connect for forwards

	local CR:client_record = test_cid(sid,cid);

	local s_data = fmt("wc:%s %s -> %s:%s", wildcard, l_port, forward_host, h_port);
	log_update_forward(CR, forward_host, h_port);
	log_session_update_event(CR, ts, "CHANNEL_SET_FWD_LISTENER_3", s_data);
}

event channel_socks4_3(ts: time, version: string, sid: string, cid: count, channel: count, path: string, h_port: port, command: count, username: string)
{
	# decoded socks4 header
	# 
	# path: path for unix domain sockets, or host name for forwards 
	# h_port: remote port to connect for forwards
	# command: typically '1' - will get translation XXX
	# username: username provided by socks request, need not be the same as the uid

	local CR:client_record = test_cid(sid,cid);

	local s_data = fmt("command: %s socks4 to %s @ %s:%s", command, username, path, h_port);
	log_update_forward(CR, path, h_port);
	log_session_update_event(CR, ts, "CHANNEL_SOCKS4_3", s_data);
}

event channel_socks5_3(ts: time, version: string, sid: string, cid: count, channel: count, path: string, h_port: port, command: count)
{
	# decoded socks5 header: this can be called multiple times per channel
	#  since the ports5 interface is somewhat more complicated
	# 
	# path: path for unix domain sockets, or host name for forwards 
	# h_port: remote port to connect for forwards
	# command: see const set for additional data

	local CR:client_record = test_cid(sid,cid);

	local s_data = fmt("command: %s[%s] socks5 to %s:%s",  socks5_header_types[command], command, path, h_port);
	log_update_forward(CR, path, h_port);
	log_session_update_event(CR, ts, "CHANNEL_SOCKS5_3", s_data);
}


event session_channel_request_3(ts: time, version: string, sid: string, cid: count, pid: int, channel: count, rtype: string)
{
	# This is a request for a channel type - the value will be filled
	#  in via the new_channel event, but this is where things are actually requested
	#
	# rtype values are: shell, exec, pty-req, x11-req, auth-agent@openssh.com, subsystem, env
	#

	local CR:client_record = test_cid(sid,cid);

	local s_data = fmt("%s", to_upper(rtype));

	if ( to_upper(rtype) == "SUBSYSTEM" ) {
		# In an effort to track subsystem events like sftp, we need to get an index entry 
		#  for the cid lookup based on sid + pid
		# If there is a value in place we run it over - it should have been cleaned up
		#  in the session_exit event...

        	local split_cln = split(sid, /:/);
        	local t_sid = fmt("%s:%s", split_cln[2], split_cln[3]);

		cid_lookup[t_sid, pid] = cid;
	}

	log_session_update_event(CR, ts, "SESSION_CHANNEL_REQUEST_3", s_data);
}

event session_do_auth_3(ts: time, version: string, sid: string, cid: count, atype: count, type_ret: count)
{
	# This is for version 1 of the protocol.  Seems like a great deal of work 
	#  for something that I really hope not to see ....
	#
	# Prepares for an interactive session.  This is called after the user has
	# been successfully authenticated.  During this message exchange, pseudo
	# terminals are allocated, X11, TCP/IP, and authentication agent forwardings
	# are requested, etc.
	#
	# type_ret: value indicating attempt/success/failure w/ 2/1/0

	local t_type_ret: string;

	if ( type_ret == 2 ) 
		t_type_ret = "ATTEMPT";
	else if ( type_ret == 1 )
		t_type_ret = "SUCCESS";
	else
		t_type_ret = "FAIL";

	local s_data = fmt("%s %s", channel_name[atype], t_type_ret);

	# no channel data here
	local CR:client_record = test_cid(sid,cid);
	log_session_update_event(CR, ts, "SESSION_DO_AUTH_3", s_data);
}

event session_exit_3(ts: time, version: string, sid: string, cid: count, channel: count, pid: count, ststus: count)
{
	local CR:client_record = test_cid(sid,cid);

	# on session exit, remove the entry asosciated with the subsystem
        local split_cln = split(sid, /:/);
        local t_sid = fmt("%s:%s", split_cln[2], split_cln[3]);
	
	if ( [t_sid,pid] in cid_lookup ) {
		delete cid_lookup[t_sid, pid];
	}

	log_session_update_event(CR, ts, "SESSION_EXIT_3", "SESSION_EXIT_3");
}

event session_input_channel_open_3(ts: time, version: string, sid: string, cid: count, tpe: count, ctype: string, rchan: int, rwindow: int, rmaxpack: int)
{
	# tpe: channel type as def in channel_name
	# ctype: one of { session, direct-tcpip, tun@openssh.com }
	# rchan: channel identifier for remote peer
	# rwindow: window size for channel
	# rmaxpack: max 'packet' for remote window 
	#

	local CR:client_record = test_cid(sid,cid);
	# XXX 
	# rchan is a guess - look and see what the actual values are
	#
	
	if ( int_to_count(rchan) !in CR$channel_type )
		{
			CR$channel_type[int_to_count(rchan)] = "unknown";
		}

	local s_data = fmt("ctype %s rchan %d win %d max %d",  
		ctype, rchan, rwindow, rmaxpack);

	log_update_channel(CR, int_to_count(rchan));
	log_session_update_event(CR, ts, "SESSION_INPUT_CHANNEL_OPEN_3", s_data);
}

event session_new_3(ts: time, version: string, sid: string, cid: count, pid: int, ver: string)
{
	local CR:client_record = test_cid(sid,cid);

	log_update_host(CR, print_sid(sid) );
	log_session_update_event(CR, ts, "SESSION_NEW_3", "SESSION_NEW_3");

	# In an effort to track subsystem events like sftp, we need to get an index entry 
	#  for the cid lookup based on sid + pid
	# If there is a value in place we run it over - it should have been cleaned up
	#  in the session_exit event...

        #local split_cln = split(sid, /:/);
        #local t_sid = fmt("%s:%s", split_cln[2], split_cln[3]);
	#
	#cid_lookup[t_sid, pid] = cid;
}

event session_remote_do_exec_3(ts: time, version: string, sid: string, cid: count, channel: count, ppid: count, command: string)
{
	# This is called to fork and execute a command.  If another command is
	#  to be forced, execute that instead.

	local CR:client_record = test_cid(sid,cid);
	register_cid(sid,cid,ppid);

	local s_data = fmt("%s", str_shell_escape(command));
	log_session_update_event(CR, ts, "SESSION_REMOTE_DO_EXEC_3", s_data);
}

event session_remote_exec_no_pty_3(ts: time, version: string, sid: string, cid: count, channel: count, ppid: count, command: string)
{
	# This is called to fork and execute a command when we have no tty.  This
	#  will call do_child from the child, and server_loop from the parent after
	#  setting up file descriptors and such.

	local CR:client_record = test_cid(sid,cid);
	register_cid(sid,cid,ppid);

	local s_data = fmt("%s", str_shell_escape(command));
	log_session_update_event(CR, ts, "SESSION_REMOTE_DO_EXEC_NO_PTY_3", s_data);
}

event session_remote_exec_pty_3(ts: time, version: string, sid: string, cid: count, channel: count, ppid: count, command: string)
{
	# This is called to fork and execute a command when we have a tty.  This
	#  will call do_child from the child, and server_loop from the parent after
	#  setting up file descriptors, controlling tty, updating wtmp, utmp,
	#  lastlog, and other such operations.

	local CR:client_record = test_cid(sid,cid);
	register_cid(sid,cid,ppid);

	local s_data = fmt("%s", str_shell_escape(command));
	log_session_update_event(CR, ts, "SESSION_REMOTE_DO_EXEC_PTY_3", s_data);
}

event session_request_direct_tcpip_3(ts: time, version: string, sid: string, cid: count, channel: count, originator: string, orig_port: port, target: string, target_port: port, i: count)
{
	local CR:client_record = test_cid(sid,cid);

	local s_data = fmt("%s:%s -> %s:%s", originator, orig_port,target, target_port);
	log_update_forward(CR, target, target_port);
	log_session_update_event(CR, ts, "SESSION_REQUEST_DIRECT_TCPIP_3", s_data);
}

event session_tun_init_3(ts: time, version: string, sid: string, cid: count, channel: count, mode: count)
{
	# mode = { SSH_TUNMODE_POINTOPOINT | SSH_TUNMODE_ETHERNET }
	local CR:client_record = test_cid(sid,cid);

	local s_data = fmt("%s",  tunnel_type[mode]);
	log_session_update_event(CR, ts, "SESSION_TUN_INIT_3", s_data);
}

event session_x11fwd_3(ts: time, version: string, sid: string, cid: count, channel: count, display: string)
{
	# the string 'display' is generated from the following c code snippet:
	# session.c: 
	#	snprintf(display, sizeof display, "%.400s:%u.%u", hostname,
	#	    s->display_number, s->screen);

	local CR:client_record = test_cid(sid,cid);

	local s_data = fmt("%s", display);
	log_session_update_event(CR, ts, "SESSION_X11FWD_INIT_3", s_data);
}


event sshd_connection_end_3(ts: time, version: string, sid: string, cid: count, r_addr: addr, r_port: port, l_addr: addr, l_port: port)
{
	local CR:client_record = test_cid(sid,cid);

	local s_data = fmt("%s:%s -> %s:%s", r_addr, r_port, l_addr, l_port);
	log_session_update_event(CR, ts, "SSHD_CONNECTION_END_3", s_data);
}

event sshd_connection_start_3(ts: time, version: string, sid: string, cid: count, int_list: string, r_addr: addr, r_port: port, l_addr: addr, l_port: port, i: count)
{
	local CR:client_record = test_cid(sid,cid);

	# update CR values with values from this event, otherwise they will remain default.
	CR$id$orig_h = r_addr;
	CR$id$orig_p = r_port;
	CR$id$resp_h = l_addr;
	CR$id$resp_p = l_port;

	s_records[sid]$c_records[cid] = CR;

	local s_data = fmt("%s:%s -> %s:%s %s", r_addr, r_port, l_addr, l_port, int_list);
	log_update_host(CR, print_sid(sid));
	log_session_update_event(CR, ts, "SSHD_CONNECTION_START_3", s_data);
}

event sshd_exit_3(ts: time, version: string, sid: string, h: addr, p: port)
{
	local t_sid: server_record;
	t_sid = test_sid(sid);

	NOTICE([$note=SSHD_Exit,
		$msg=fmt("iSSHD instance %s exit", sid)]);

	log_server_session(t_sid, ts, "SSHD_EXIT_3", "SSHD_EXIT_3");
}

event sshd_restart_3(ts: time, version: string, sid: string, h: addr, p: port)
{
	local t_sid: server_record;
	t_sid = test_sid(sid);

	t_sid$start_time = ts;
	s_records[sid] = t_sid;

	log_server_session(t_sid, ts, "SSHD_RESTART_3", "SSHD_RESTART_3");
}

event sshd_server_heartbeat_3(ts: time, version: string, sid: string,  dt: count)
	{
	# no server record, no heartbeat data ...
	if ( sid !in s_records )
		return; 

	local SR:server_record = test_sid(sid);
	local isRemote: bool = is_remote_event();
	local ts_d:double = time_to_double(ts);
	local trigger_heartbeat: bool = F;
	local state = SR$heartbeat_state;

	if ( isRemote ) {

		if ( state == HB_INIT ) {
			# first time we have seen this heartbeat - fill
			#  in the base values and set a notice

			SR$heartbeat_state = HB_OK;
			SR$heartbeat_last = ts_d;
			trigger_heartbeat = T;

			NOTICE([$note=SSHD_NewHeartbeat,
				$msg=fmt("New communication from %s", sid)]);
			}

		if ( state == HB_OK ) 
			# just another heartbeat...
			SR$heartbeat_last = ts_d;

		if ( state == HB_ERROR ) {
			# reset last seen timestamp and state value
			SR$heartbeat_last = ts_d;
			SR$heartbeat_state = HB_OK;
			}

		# now update 
		s_records[sid] = SR;

		} # end isRemote

	if ( !isRemote ) {
		if ( state == HB_INIT ) 
			# this should not happen since we have not seen the initial
			#  remote heartbeat.  best to just quietly go
			return;

		if ( state == HB_OK ) {
			# classic state test- just make sure that not too much time
			#  has passed and whatnot

			# Interval test
			if ( ( ts_d - SR$heartbeat_last ) > interval_to_double(heartbeat_timeout) ) {
			
				# A sufficient interval of time has passed that we are interested
				#  in what is going on.  heartbeat_tmeout = 300 sec by default
			
				NOTICE([$note=SSHD_Heartbeat,
					$msg=fmt("Lost communication to %s, dt=%s",
						sid, ts_d - SR$heartbeat_last)]);
			
				# reset this value to avoid redundant notices
				SR$heartbeat_state = HB_ERROR;

				} # End interval test

			trigger_heartbeat = T;	
			}

		if ( state == HB_ERROR )
			# not much else to do here - trigger another check and keep on going 
			trigger_heartbeat = T;	

		} # end !isRemote

	# send a new heartbeat
	if ( trigger_heartbeat ) {

		local hb_sched:interval = heartbeat_timeout + rand(10) * 1 sec;
		local new_time = double_to_time( interval_to_double(hb_sched) + ts_d );

		schedule hb_sched { sshd_server_heartbeat_3(new_time, version, sid, 0) };
		}

	}
event sshd_start_3(ts: time, version: string, sid: string, h: addr, p: port)
{
	local t_sid: server_record;
	t_sid = test_sid(sid);

	t_sid$start_time = ts;
	s_records[sid] = t_sid;

	NOTICE([$note=SSHD_Start,
		$msg=fmt("iSSHD instance %s", sid)]);

	log_server_session(t_sid, ts, "SSHD_START_3", "SSHD_START_3");
}

event bro_init() &priority=5
{
	Log::create_stream(SSHD_CORE::LOG, [$columns=Info]);
}
