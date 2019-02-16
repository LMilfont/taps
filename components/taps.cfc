<!---

   Component : taps.cfc
   Author    : Luiz Milfont
   Date      : 01/24/2019
   Usage     : This component is used to perfome business-tied operations.
   
--->


<cfcomponent name="taps">

   <!--- Constants --->
   <cfset rewardsDelivered="rewards_delivered">
   <cfset rewardsPending="rewards_pending">
   <cfset tenMinutes = 600> <!--- In seconds --->
   <cfset fiftySeconds = 50>

   <!--- Methods ---> 

   <!--- This is the TAPS core routine. It distributes the share of the rewards to the delegators  --->
   <!--- Some information is stored in the local database in the process, so it is possible to check them later --->
   <!--- Log files with the results from executing tezos-client transfers are also written, in the folder taps/logs --->
   <!--- When operating in Simulation mode, everything will be recorded, but payments will not be made for real --->
   <cffunction name="distributeRewards">
      <cfargument name="localPendingRewardsCycle" required="true" type="number" />
      <cfargument name="networkPendingRewardsCycle" required="true" type="number" />
      <cfargument name="delegators" required="true" type="query" />

      <cfset var paymentDate = #dateFormat(now(),'mm-dd-yyyy')#>
      <cfset var settings = "">
      <cfset var operationMode = "">
      <cfset var clientPath = "">
      <cfset var nodeAlias = "">
      <cfset var baseDir = "">
      <cfset var operationResult = "">

      <!--- Override Lucee Administrator settings for request timeout --->
      <cfsetting requestTimeout = #tenMinutes#>

      <!--- First, update the payment date and the status in the local database --->
      <cfquery name="update_local" datasource="ds_taps">   
          UPDATE payments SET
             DATE = parsedatetime(<cfqueryparam value="#paymentDate#" sqltype="CF_SQL_VARCHAR" maxlength="20">, 'MM-dd-yyyy'),
             RESULT = '#rewardsDelivered#'
             WHERE BAKER_ID = <cfqueryparam value="#application.bakerId#" sqltype="CF_SQL_VARCHAR" maxlength="50">
             AND CYCLE = <cfqueryparam value="#arguments.localPendingRewardsCycle#" sqltype="CF_SQL_NUMERIC" maxlength="50">
      </cfquery>

      <!--- Now, insert a new line with the current pending rewards cycle --->
      <cfquery name="save_local_pending" datasource="ds_taps">   
         INSERT INTO payments (BAKER_ID, CYCLE, DATE, RESULT, TOTAL)
	 VALUES
	 (
	    <cfqueryparam value="#application.bakerId#" sqltype="CF_SQL_VARCHAR" maxlength="50">,
            <cfqueryparam value="#arguments.networkPendingRewardsCycle#" sqltype="CF_SQL_NUMERIC" maxlength="50">,
	    parsedatetime(<cfqueryparam value="#paymentDate#" sqltype="CF_SQL_VARCHAR" maxlength="20">, 'MM-dd-yyyy'),
           '#rewardsPending#',
	   0
         )
      </cfquery>

      <!--- ErrorArray will be used to store failed transfers, so it will be possible to know who didn't receive rewards --->
      <cfset errorArray = ArrayNew(1)> 
      <cfset i = 1>
      <cfset totalPaid = 0>
     
      <!--- Create a log file identified by current cycle --->
      <cffile file="../logs/payments_#arguments.localPendingRewardsCycle#.log" action="write" output="">

      <!--- Check the mode TAPS is working in (Simulation or On) --->
      <!--- Also, get client_path, base_dir, and node_alias from the local database --->
      <cfinvoke component="database" method="getSettings" returnVariable="settings">
      <cfif #settings.recordCount# GT 0>
         <cfset operationMode = #settings.mode#>
         <cfset clientPath = "#settings.client_path#">
         <cfset baseDir = "#settings.base_dir#">
         <cfset nodeAlias = "#settings.node_alias#">          
      <cfelse>
         <cfset operationMode = "#application.mode_desc_try#">
      </cfif>

      <!--- Make rewards payment to delegators --->  
      <!--- Loop through delegators and do transfers (or simulate them, depending on mode) --->
      <cfloop query="#arguments.delegators#">
         <!--- We always keep 3 cycles of rewards information in the local database, so we have to get only the rewards --->
         <!--- corresponding to the pending_reward cycle --->
         <cfif #arguments.delegators.cycle# EQ #arguments.localPendingRewardsCycle#>
               <!--- Initialize delegator's payment value with zero --->
               <cfset paymentValue = 0>

               <!--- Calculate delegator's payment considering custom fee --->
               <cfquery name="local_get_fee" datasource="ds_taps">
                  SELECT FEE FROM delegatorsFee
                  WHERE BAKER_ID = <cfqueryparam value="#application.bakerId#" sqltype="CF_SQL_VARCHAR" maxlength="50">
                  AND   ADDRESS  = <cfqueryparam value="#delegators.address#" sqltype="CF_SQL_VARCHAR" maxlength="50"> 
               </cfquery>

               <!--- If there is a fee stored in the local database for this delegator, use it. Otherwise, pay rewards without considering fee --->
               <cfif #local_get_fee.recordCount# GT 0>
                  <cfset paymentValue = #int(arguments.delegators.rewards * ((100 - local_get_fee.fee) / 100) * 100) / 100#>
               <cfelse>
                  <cfset paymentValue = #arguments.delegators.rewards#>
               </cfif>

               <!--- Now we have to build dynamically the command that will be passed to the Tezos-client to be executed --->

               <!--- Build Tezos-client transfer command --->
               <cfset tezosCommand = "@@@clientPath@@@/tezos-client --base-dir @@@baseDir@@@ transfer @@@value@@@ from @@@nodeAlias@@@ to @@@destAddress@@@">
               
               <!--- Decide whether to do real transfers or simulate them, according to the configured mode --->
               <cfif #operationMode# EQ "#application.mode_desc_try#">
                  <cfset tezosArguments = "--fee 0.05 --dry-run">         <!--- Dry-run = Simulation only --->
                  <cfset operationResult="simulated">
               <cfelseif #operationMode# EQ "#application.mode_desc_yes#">
                  <cfset tezosArguments = "--fee 0.05">                   <!--- For real! Will pay! --->
                  <cfset operationResult="paid">
               <cfelse> <!--- fallback is simulation mode --->
                  <cfset tezosArguments = "--fee 0.05 --dry-run">         <!--- Dry-run = Simulation only --->
                  <cfset operationResult="simulated"> 
              </cfif>

               <!--- Make proper substitutions in the dynamic command --->
               <cfset tezosCommand = replace(tezosCommand, "@@@clientPath@@@", "#clientPath#")>
               <cfset tezosCommand = replace(tezosCommand, "@@@baseDir@@@", "#baseDir#/.tezos-client")>
               <cfset tezosCommand = replace(tezosCommand, "@@@value@@@", "#paymentValue#")>
               <cfset tezosCommand = replace(tezosCommand, "@@@nodeAlias@@@", "#nodeAlias#")>
               <cfset tezosCommand = replace(tezosCommand, "@@@destAddress@@@", "#arguments.delegators.address#")>

               <!--- Now we have the dynamic command ready to be executed by Tezos-client. Let's do it --->

               <cftry>

                   <!-- Execute Tezos-client transfer command --->
	           <cfexecute variable="result"
                              errorvariable="error"
                              timeout="#tenMinutes#"
                              terminateontimeout = false
                              name="#tezosCommand#"
                              arguments="#tezosArguments#">
                   </cfexecute>

		   <cfoutput>

                      <!--- Write Log files with Tezos-client execution results in folder taps/logs --->
                      <cffile file="../logs/payments_#arguments.localPendingRewardsCycle#.log" action="append" output="#result#">

                      <!--- Save the delegator payment information in the local database --->
                      <cfquery name="save_local_pending" datasource="ds_taps">   
			    INSERT INTO delegatorsPayments (BAKER_ID, CYCLE, ADDRESS, DATE, RESULT, TOTAL)
			    VALUES
			    (
			        <cfqueryparam value="#application.bakerId#" sqltype="CF_SQL_VARCHAR" maxlength="50">,
                                <cfqueryparam value="#arguments.localPendingRewardsCycle#" sqltype="CF_SQL_NUMERIC" maxlength="50">,
                                <cfqueryparam value="#arguments.delegators.address#" sqltype="CF_SQL_VARCHAR" maxlength="50">,
        			parsedatetime(<cfqueryparam value="#paymentDate#" sqltype="CF_SQL_VARCHAR" maxlength="20">, 'MM-dd-yyyy'),
                                '#operationResult#',
                                <cfqueryparam value="#paymentValue#" sqltype="CF_SQL_NUMERIC" maxlength="50">
			    )
		      </cfquery>

                      <!--- Accumulate the total paid --->
                      <cfset totalPaid = totalPaid + #paymentValue#>

                   </cfoutput>

               <cfcatch>
                  <!--- If some error ocurred in Tezos-client transfer execution --->
                  <cfset errorArray[i] = "#arguments.delegators.address#"> 
                  <cfset i = i + 1>
                  
                  <!--- Save the error information on delegator payment table in the local database --->
		  <cfquery name="save_local_pending" datasource="ds_taps">   
		    INSERT INTO delegatorsPayments (BAKER_ID, CYCLE, ADDRESS, DATE, RESULT, TOTAL)
		    VALUES
		    (
		        <cfqueryparam value="#application.bakerId#" sqltype="CF_SQL_VARCHAR" maxlength="50">,
        		<cfqueryparam value="#arguments.localPendingRewardsCycle#" sqltype="CF_SQL_NUMERIC" maxlength="50">,
                        <cfqueryparam value="#arguments.delegators.address#" sqltype="CF_SQL_VARCHAR" maxlength="50">,
        		parsedatetime(<cfqueryparam value="#paymentDate#" sqltype="CF_SQL_VARCHAR" maxlength="20">, 'MM-dd-yyyy'),
        		'error',
        		0 
		    )
		  </cfquery>

               </cfcatch>
               </cftry>
         </cfif>
      </cfloop>

      <!--- Then, update the payments result and total, in the local database --->
      <cfquery name="update_local" datasource="ds_taps">   
          UPDATE payments SET
             <cfif #ArrayLen(errorArray)# EQ 0>RESULT = 'paid'<cfelse>RESULT = 'errors'</cfif>,
             TOTAL = #totalPaid#
          WHERE BAKER_ID = <cfqueryparam value="#application.bakerId#" sqltype="CF_SQL_VARCHAR" maxlength="50">
          AND CYCLE = <cfqueryparam value="#arguments.localPendingRewardsCycle#" sqltype="CF_SQL_NUMERIC" maxlength="50">
          AND DATE = parsedatetime(<cfqueryparam value="#paymentDate#" sqltype="CF_SQL_VARCHAR" maxlength="20">, 'MM-dd-yyyy')
       </cfquery>

      <!--- Restore default Lucee Administrator settings for request timeout --->
      <cfsetting requestTimeout = #fiftySeconds#>

   </cffunction>


   <cffunction name="authenticate" returnType="boolean">
      <cfargument name="user" required="true" type="string" />
      <cfargument name="passdw" required="true" type="string" />

      <cfset var result = false>

      <!--- Verify if there is no user configured yet --->
      <cfquery name="verify_configured_user" datasource="ds_taps">
         SELECT pass_hash, hash_salt
         FROM settings
      </cfquery>

      <!--- If there is a user and also a saved password hash --->
      <cfif (#verify_configured_user.recordcount# GT 0) and (#len(verify_configured_user.pass_hash)# GT 0)>
         <!--- Verify if the hash matches --->
         <cfset salt = #verify_configured_user.hash_salt#>
         <cfset hashedPassword = Hash(#arguments.passdw# & #salt#, "SHA-512") />

         <cfif #verify_configured_user.pass_hash# EQ #hashedPassword#>
            <cfset result = true>
         </cfif>

      <cfelse>
         <cfif #arguments.user# eq "admin" and #arguments.passdw# EQ "admin">
            <cfset result = true>
         </cfif>
      </cfif>

      <cfif #result# EQ true>
         <cfset application.user = "#arguments.user#">
      </cfif>

      <cfreturn result>
   </cffunction>

   <!--- Create Scheduled task to query TzScan from time to time --->
   <!--- This is the heart of TAPS. This is responsible to detect when a cycle changes --->
   <cffunction name="createScheduledTask" returnType="boolean">
      <cfargument name="port" required="true" type="number">

      <cfset var result = false>
      <cfset var settings = "">
      <cfset var interval = 0>

      <cftry>

         <!--- Get the user-configured fetch interval from local database --->
         <cfinvoke component="components.database" method="getSettings" returnVariable="settings">
        
         <cfif #settings.recordCount# GT 0>

            <!--- Convert to seconds --->
            <cfset interval = #settings.update_freq# * 60>

            <cfschedule
                  action = "update"
                  task = "fetchTzScan"
                  interval = "#interval#"
                  port = "#arguments.port#"
                  proxyServer="#application.proxyServer#"
                  proxyPort="#application.proxyPort#"
                  publish = "no"
                  startDate = "01/01/1970"
                  startTime = "00:00 AM"
                  url="http://127.0.0.1/taps/script_fetch.cfm"
                  operation="HTTPRequest" />

            <!--- After creating the scheduled task, we run it for the first time, to populate local database --->
            <cfschedule
                  action = "run"
                  task = "fetchTzScan" />
         
            <cfset result = true>
 
        <cfelse>
            <cfset result = false>
         </cfif>

      <cfcatch>
         <cfset result = false>
      </cfcatch>
      </cftry>

      <cfreturn result>
   </cffunction>

   <!--- This method do a factory-reset on the system --->
   <!--- It will clear all data previously stored in local database. But will not delete the logs in folder taps/logs --->
   <!--- It will delete the scheduled task that fetches TzScan --->
   <cffunction name="resetTaps" returnType="boolean">
      <cfargument name="user" required="true" type="string" />
      <cfargument name="passdw" required="true" type="string" />
      <cfargument name="passdw2" required="true" type="string" />

      <cfset var result = false>
      <cfset var authResult = false>

      <!--- Test if fields have value --->
      <cfif len(#arguments.user#) GT 0 and
            len(#arguments.passdw#) GT 0 and
            len(#arguments.passdw2#) GT 0>

	      <!--- Test if passwords match --->
	      <cfif #arguments.passdw# EQ #arguments.passdw2#>

		      <!--- Verify if pair user/passwd is able to authenticate --->
		      <cfset authResult = authenticate("#arguments.user#","#arguments.passdw#")>

                      <cfif #authResult# EQ true>
			      <cftry>
				 <!--- Delete Scheduled Task --->
				 <cfschedule
				     action = "delete"
				     task = "fetchTzScan" />
			  
				 <!--- Erase all table data --->
				 <cfquery name="reset_taps" datasource="ds_taps">
				    DELETE FROM settings;
				    DELETE FROM payments;
				    DELETE FROM delegatorsPayments;
				    DELETE FROM delegatorsFee;
				 </cfquery>

				 <!--- Delete all memory caches --->
				 <cfobjectcache action="CLEAR">

				 <!--- Clear application-specific variables --->
				 <cfset application.bakerId = "">
				 <cfset application.fee="">
				 <cfset application.freq="">
				 <cfset application.port=8888>
                                 <cfset application.user = "">

				 <cfset result = true>

			      <cfcatch>
				 <cfset result = false>
			      </cfcatch>
			      </cftry>

            <cfelse>
               <cfset result = false>
            </cfif>

         <cfelse>
            <cfset result = false>
         </cfif>

      <cfelse>
         <cfset result = false>
      </cfif>

      <cfreturn result>
   </cffunction>

   <!--- Pause Scheduled task to stop TAPS (mode off) --->
   <!--- This will PAUSE the scheduled-task, which means that TAPS will neither simulate nor make real payments --->
   <!--- It will just stop querying TzScan --->
   <cffunction name="pauseScheduledTask" returnType="boolean">
      <cfargument name="port" required="true" type="number">

      <cfset var result = false>
      <cfset var settings = "">

      <cftry>

         <cfinvoke component="components.database" method="getSettings" returnVariable="settings">
        
         <cfif #settings.recordCount# GT 0>

            <cfschedule
                  action = "pause"
                  task = "fetchTzScan" />
         
            <cfset result = true>
 
         <cfelse>
            <cfset result = false>
         </cfif>

      <cfcatch>
         <cfset result = false>
      </cfcatch>
      </cftry>

      <cfreturn result>
   </cffunction>

   <!--- Resume Scheduled task to run TAPS (mode simulation or on) --->
   <!--- This will make TzScan fetches active again --->
   <cffunction name="resumeScheduledTask" returnType="boolean">
      <cfargument name="port" required="true" type="number">

      <cfset var result = false>
      <cfset var settings = "">

      <cftry>

         <cfinvoke component="components.database" method="getSettings" returnVariable="settings">
        
         <cfif #settings.recordCount# GT 0>

            <cfschedule
                  action = "resume"
                  task = "fetchTzScan" />
         
            <cfset result = true>
 
         <cfelse>
            <cfset result = false>
         </cfif>

      <cfcatch>
         <cfset result = false>
      </cfcatch>
      </cftry>

      <cfreturn result>
   </cffunction>


   <!--- Health-check: If TAPS is missing the scheduled-task, re-create it, based on user settings --->
   <cffunction name="healthCheck">
      <cfset var result = false>
      <cfset var settings = "">

      <cftry>
         <!--- Checks if there is a saved configuration. If true, it MUST exist a scheduled-task --->
         <cfinvoke component="components.database" method="getSettings" returnVariable="settings">
        
         <cfif #settings.recordCount# GT 0>
            <!--- Checks if there is a scheduled-task named "fetchTzScan" --->
            <cfschedule
               action = "list"
               returnVariable="myTasks" />

            <cfquery name="get_taps_task" dbtype="query">
               select task from myTasks
               where task = 'fetchTzScan'
            </cfquery>

            <cfif #get_taps_task.recordcount# EQ 0>
               <!--- If there is no scheduled-task named "fetchTzScan", then create it --->
               <cfset myTask = createScheduledTask("#application.port#")>

               <!--- After having re-created the scheduled-task, we need to set its status according to
                     the user configured status (Off, Simulation, or ON) --->
               <cfif #settings.mode# EQ "#application.mode_desc_no#"> <--- Off --->
                  <!--- Pause the scheduled-task --->
                  <cfset myTask = pauseScheduledTask("#application.port#")>
               <cfelse>
                  <!--- Resume the scheduled-task --->
                  <cfset myTask = ResumeScheduledTask("#application.port#")>
               </cfif>

            </cfif>
         </cfif>

      <cfcatch>
      </cfcatch>
      </cftry>
   </cffunction>


</cfcomponent>
