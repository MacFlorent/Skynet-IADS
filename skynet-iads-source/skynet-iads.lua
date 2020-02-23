do

--V 1.0:
-- TODO: check if jammer should be scripted with LOS, SAM sites in urban area don't always return a propper LOS, maybe just add the height +10 m for LOS calcualtion?

-- to test: 1 command center, 1 command power source (damage each one individually): ok
-- to test: 2 command centers, 2 command power sources (damage each one individually): ok
-- to test: SAM 1 power source, 1 com center (damage each one individually): ok
-- to test: EW Radar, 1 connection node, 2 power source (damage each one individually): ok

-- V 1.1:
-- TODO: code HARM defence, check if SAM Site or EW sees HARM, only then start defence -> SAM Sites with no HARM defence would shut down, and if mobile move the emitter 50 - 100 m. code lag ~30 secs until unit moves
-- TODO: SAM Sites could go active if a bandit is within visual detection range, e.g. > 10 nm.
-- TODO: SAM could have decoy emitters to trick HARM in to homing in to the wrong radar
-- TODO: if SAM site has run out of missiles shut it down

-- V1.2:
-- TODO: decide if more SAM Sites need to be jammable, eg blue side.
-- TODO: extrapolate flight path to get SAM to active so that it can fire as aircraft aproaches max range	
-- TODO: add sneaky sam tactics, like stay dark until bandit has passed the sam then go live
-- TODO: merge SAM contacts with the ones it gets from the IADS, it could be that the SAM sees something the IADS does not know about, later on add this data back to the IADS
-- TODO: add random failures in IFF so enemy planes trigger IADS SAM activation by mistake
-- TODO: electronic Warfare: add multiple planes via script around the Jamming Group, get SAM to target those
-- TODO: after one connection node or powerplant goes down and there are others, add a delay until the sam site comes online again (configurable)
-- TODO: SA-10 Launch distance seems off
-- TODO: EW Radars should also be jammable, what should the effects be on IADS target detection? eg activate sam sites in the bearing ot the jammer source, since distance calculation would be difficult, when tracked by 2 EWs, distance calculation should improve due to triangulation?
-- TODO: check if SAM has LOS to target, if not, it should not activate -> not quite sure of that is a good idea due to LOS calcualtion issues

-- To test: which SAM Types can engage air weapons, especially HARMs?
-- To test: shall sam turn ai off or set state to green, when going dark? Does one method have an advantage?

--[[
SAM Sites that engage HARMs:
SA-15
SA-10

SAM Sites that ignore HARMS:
SA-11 (test again)
SA-6
]]--

-- Compile Scripts: type sam-types-db.lua  skynet-iads-abstract-element.lua skynet-iads-command-center.lua skynet-iads-early-warning-radar.lua skynet-iads-jammer.lua skynet-iads-sam-site.lua skynet-iads.lua > skynet-iads-compiled.lua

SkynetIADS = {}
SkynetIADS.__index = SkynetIADS

SkynetIADS.database = samTypesDB

function SkynetIADS:create()
	local iads = {}
	setmetatable(iads, SkynetIADS)
	iads.earlyWarningRadars = {}
	iads.samSites = {}
	iads.commandCenters = {}
	iads.ewRadarScanMistTaskID = nil
	iads.coalition = nil
	self.debugOutput = {}
	self.debugOutput.IADSStatus = false
	self.debugOutput.samWentDark = false
	self.debugOutput.contacts = false
	self.debugOutput.radarWentLive = false
	self.debugOutput.ewRadarNoConnection = false
	self.debugOutput.samNoConnection = false
	self.debugOutput.jammerProbability = false
	self.debugOutput.addedEWRadar = false
	self.debugOutput.hasNoPower = false
	return iads
end

function SkynetIADS:setCoalition(item)
	if item then
		local coalitionID = item:getCoalition()
		if self.coalitionID == nil then
			self.coalitionID = coalitionID
		end
	--	if getmetatable(item) == StaticObject then
	--		trigger.action.outText(item:getName(), 10)
	--		trigger.action.outText(self.coalitionID.." "..coalitionID, 10)
	--	end
		if self.coalitionID ~= coalitionID then
			trigger.action.outText("WARNING: Element: "..item:getName().." has a different coalition than the IADS", 10)
		end
	end
end

function SkynetIADS:getCoalition()
	return self.coalitionID
end

function SkynetIADS:addEarlyWarningRadarsByPrefix(prefix)
	for unitName, unit in pairs(mist.DBs.unitsByName) do
		local pos = string.find(string.lower(unitName), string.lower(prefix))
		--somehow the MIST unit db contains StaticObject, we check to see we only add Units
		local unit = Unit.getByName(unitName)
		if pos and pos == 1 and unit then
			self:addEarlyWarningRadar(unitName)
		end
	end
end

function SkynetIADS:addEarlyWarningRadar(earlyWarningRadarUnitName, powerSource, connectionNode)
	local earlyWarningRadarUnit = Unit.getByName(earlyWarningRadarUnitName)
	if earlyWarningRadarUnit == nil then
		trigger.action.outText("WARNING: You have added an EW Radar that does not exist, check name of Unit in Setup and Mission editor: "..earlyWarningRadarUnitName, 10)
		return
	end
	self:setCoalition(earlyWarningRadarUnit)
	local ewRadar = SkynetIADSEWRadar:create(earlyWarningRadarUnit, self)
	self:addPowerAndConnectionNodeTo(earlyWarningRadarUnitName, powerSource, connectionNode)
	table.insert(self.earlyWarningRadars, ewRadar)
end

function SkynetIADS:setOptionsForEarlyWarningRadar(unitName, powerSource, connectionNode)
		local update = false
		for i = 1, #self.earlyWarningRadars do
			local ewRadar = self.earlyWarningRadars[i]
			if string.lower(ewRadar:getDCSName()) == string.lower(unitName) then
				self:addPowerAndConnectionNodeTo(ewRadar, powerSource, connectionNode)
				update = true
			end
		end
		if update == false then
			trigger.action.outText("WARNING: you tried to set options for an EW radar that does not exist: "..unitName, 10)
		end
end

function SkynetIADS:addSamSitesByPrefix(prefix, autonomousMode)
	for groupName, groupData in pairs(mist.DBs.groupsByName) do
		local pos = string.find(string.lower(groupName), string.lower(prefix))
		if pos and pos == 1 then
			self:addSamSite(groupName, nil, nil, autonomousMode)
		end
	end
end

function SkynetIADS:addSamSite(samSiteName, powerSource, connectionNode, autonomousMode)
	local samSiteDCS = Group.getByName(samSiteName)
	if samSiteDCS == nil then
		trigger.action.outText("You have added an SAM Site that does not exist, check name of Group in Setup and Mission editor", 10)
		return
	end
	self:setCoalition(samSiteDCS)
	local samSite = SkynetIADSSamSite:create(samSiteDCS, self)
	if samSite:getDBName() == "UNKNOWN" then
		trigger.action.outText("WARNING: You have added an SAM Site that Skynet IADS can not handle: "..samSite:getDCSName(), 10)
	else
		table.insert(self.samSites, samSite)
	end
	self:setOptionsForSamSite(samSiteName, powerSource, connectionNode, autonomousMode)
end

function SkynetIADS:setOptionsForSamSite(groupName, powerSource, connectionNode, autonomousMode)
	local update = false
	for i = 1, #self.samSites do
		local samSite = self.samSites[i]
		if string.lower(samSite:getDCSName()) == string.lower(groupName) then
			self:addPowerAndConnectionNodeTo(samSite, powerSource, connectionNode)
			samSite:setAutonomousBehaviour(autonomousMode)
			update = true
		end
	end
	if update == false then
		trigger.action.outText("WARNING: you tried to set options for a SAM site that does not exist: "..groupName, 10)
	end
end

function SkynetIADS:getSamSites()
	return self.samSites
end

function SkynetIADS:addPowerAndConnectionNodeTo(iadsElement, powerSource, connectionNode)
	if powerSource then
		self:setCoalition(powerSource)
		iadsElement:addPowerSource(powerSource)
	end
	if connectionNode then
		self:setCoalition(connectionNode)
		iadsElement:addConnectionNode(connectionNode)
	end
end

function SkynetIADS:addCommandCenter(commandCenter, powerSource)
	self:setCoalition(commandCenter)
	if powerSource then
		self:setCoalition(powerSource)
	end
	local comCenter = SkynetIADSCommandCenter:create(commandCenter, iads)
	comCenter:addPowerSource(powerSource)
	table.insert(self.commandCenters, comCenter)
end

function SkynetIADS:isCommandCenterAlive()
	local hasWorkingCommandCenter = (#self.commandCenters == 0)
	for i = 1, #self.commandCenters do
		local comCenter = self.commandCenters[i]
		if comCenter:getLife() > 0 and comCenter:hasWorkingPowerSource() then
			hasWorkingCommandCenter = true
			break
		else
			hasWorkingCommandCenter = false
		end
	end
	return hasWorkingCommandCenter
end

function SkynetIADS:setSamSitesToAutonomousMode()
	for i= 1, #self.samSites do
		samSite = self.samSites[i]
		samSite:goAutonomous()
	end
end

function SkynetIADS.evaluateContacts(self)
	if self:getDebugSettings().IADSStatus then
		self:printSystemStatus()
	end	
	local iadsContacts = {}
	if self:isCommandCenterAlive() == false then
		if self:getDebugSettings().noWorkingCommmandCenter then
			self:printOutput("No Working Command Center")
		end
		self:setSamSitesToAutonomousMode()
		return
	end
	for i = 1, #self.earlyWarningRadars do
		local ewRadar = self.earlyWarningRadars[i]
		if ewRadar:hasActiveConnectionNode() then
			local ewContacts = ewRadar:getDetectedTargets()
			for j = 1, #ewContacts do
				--trigger.action.outText(ewContacts[j]:getName(), 1)
				iadsContacts[ewContacts[j]:getName()] = ewContacts[j]
				--trigger.action.outText(ewRadar:getDescription().." has detected: "..ewContacts[j]:getName(), 1)	
			end
		else
			if self:getDebugSettings().ewRadarNoConnection then
				self:printOutput(ewRadar:getDescription().." no connection to Command Center")
			end
		end
	end
	for unitName, unit in pairs(iadsContacts) do
		if self:getDebugSettings().contacts then
			self:printOutput("IADS CONTACT: "..unitName.." | TYPE: "..unit:getTypeName())
		end
		--currently the DCS Radar only returns enemy aircraft, if that should change an coalition check will be required
		---Todo: currently every type of object in the air is handed of to the sam site, including bombs and missiles, shall these be removed?
		self:correlateWithSamSites(unit)
	end
	-- special case if no contacts are found by the EW radars, then shut down all the sams, this needs to be tested
	if #self.iadsContacts == 0 then
		for i= 1, #self.samSites do
			local samSite = self.samSites[i]
			samSite:clearTargetsInRange()
			samSite:goDark()
		end
	end
end

function SkynetIADS:printOutput(output)
	trigger.action.outText(output, 4)
end

function SkynetIADS:getDebugSettings()
	return self.debugOutput
end

function SkynetIADS:correlateWithSamSites(detectedAircraft)
	for i= 1, #self.samSites do
		local samSite = self.samSites[i]
		if samSite:hasActiveConnectionNode() then
			samSite:handOff(detectedAircraft)
		else
			if self:getDebugSettings().samNoConnection then
				self:printOutput(samSite:getDescription().." no connection Command Center")
				samSite:goAutonomous()
			end
		end
	end
end

-- will start going through the Early Warning Radars to check what targets they have detected
function SkynetIADS:activate()
	if self.ewRadarScanMistTaskID ~= nil then
		mist.removeFunction(self.ewRadarScanMistTaskID)
	end
	self.ewRadarScanMistTaskID = mist.scheduleFunction(SkynetIADS.evaluateContacts, {self}, 1, 5)
end

function SkynetIADS:printSystemStatus()	
	local numComCenters = #self.commandCenters
	local numIntactComCenters = 0
	local numDestroyedComCenters = 0
	local numComCentersNoPower = 0
	local numComCentersServingIADS = 0
	for i = 1, #self.commandCenters do
		local commandCenter = self.commandCenters[i]
		if commandCenter:hasWorkingPowerSource() == false then
			numComCentersNoPower = numComCentersNoPower + 1
		end
		if commandCenter:getLife() > 0 then
			numIntactComCenters = numIntactComCenters + 1
		end
		if commandCenter:getLife() > 0 and commandCenter:hasWorkingPowerSource() then
			numComCentersServingIADS = numComCentersServingIADS + 1
		end
	end
	
	numDestroyedComCenters = numComCenters - numIntactComCenters
	
	self:printOutput("COMMAND CENTERS: Serving IADS: "..numComCentersServingIADS.." | Total: "..numComCenters.." | Intact: "..numIntactComCenters.." | Destroyed: "..numDestroyedComCenters.." | No Power: "..numComCentersNoPower)
	
	local ewNoPower = 0
	local ewTotal = #self.earlyWarningRadars
	local ewNoConnectionNode = 0
	local ewActive = 0
	local ewRadarsInactive = 0

	for i = 1, #self.earlyWarningRadars do
		local ewRadar = self.earlyWarningRadars[i]
		if ewRadar:hasWorkingPowerSource() == false then
			ewNoPower = ewNoPower + 1
		end
		if ewRadar:hasActiveConnectionNode() == false then
			ewNoConnectionNode = ewNoConnectionNode + 1
		end
		if ewRadar:isActive() then
			ewActive = ewActive + 1
		end
	end
	
	ewRadarsInactive = ewTotal - ewActive
	
	self:printOutput("EW SITES: "..ewTotal.." | Active: "..ewActive.." | Inactive: "..ewRadarsInactive.." | No Power: "..ewNoPower.." | No Connection: "..ewNoConnectionNode)
	
	local samSitesInactive = 0
	local samSitesActive = 0
	local samSitesTotal = #self.samSites
	local samSitesNoPower = 0
	local samSitesNoConnectionNode = 0
	for i = 1, #self.samSites do
		local samSite = self.samSites[i]
		if samSite:hasWorkingPowerSource() == false then
			samSitesNoPower = samSitesNoPower + 1
		end
		if samSite:hasActiveConnectionNode() == false then
			samSitesNoConnectionNode = samSitesNoConnectionNode + 1
		end
		if samSite:isActive() then
			samSitesActive = samSitesActive + 1
		end
	end
	samSitesInactive = samSitesTotal - samSitesActive
	self:printOutput("SAM SITES: "..samSitesTotal.." | Active: "..samSitesActive.." | Inactive: "..samSitesInactive.." | No Power: "..samSitesNoPower.." | No Connection: "..samSitesNoConnectionNode)
end

end
