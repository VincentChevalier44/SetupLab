-- Pont ACAdvancedIA -> SpotterEnginer : description du format partagé (ac.connect), sans aucune fonction de CSP.
-- CE FICHIER EST IDENTIQUE, AU CARACTÈRE PRÈS, DANS LES DEUX APPS :
--   apps/lua/ACAdvancedIA/src/bridge_layout.lua   (écrivain : src/bridge.lua, port ac.connect dans src/applier.lua)
--   apps/lua/SpotterEnginer/src/bridge_layout.lua (lecteur : src/link.lua)
-- Deux structures :
--   hello : forme figée pour toujours (version du pont, version de l'app, battement, fermeture) ; elle dit qu'ACAdvancedIA
--           tourne et quelle version du pont il publie, même quand le lecteur ne connaît pas cette version ;
--   data  : état publié à chaque image, clé suivie du numéro de version (une autre version ne se connecte jamais).
-- Conventions : indices de voiture d'AC (0 = première voiture, -1 = aucune) ; durées en secondes restantes ou écoulées
-- (jamais d'instant absolu : l'horloge d'ACAdvancedIA s'arrête en pause et repart de zéro au-delà de 24 h) ; un
-- événement d'une image est un compteur (serial) qui change, jamais un booléen d'une image.
local L={}
L.version=2
L.helloKey='ACAdvancedIA.Bridge.Hello'
L.dataKey='ACAdvancedIA.Bridge.Data.v2'
L.maxCars=61
-- Types : bool, int (int32), uint (uint32), float, double, string (capacité en octets, fin comprise).
L.hello={
 {'bridgeVersion','int'},{'release','string',24},{'heartbeat','uint'},{'closed','bool'},
}
L.fields={
 -- État d'ACAdvancedIA
 {'serial','uint'},{'enabled','bool'},{'ready','bool'},{'panic','bool'},{'online','bool'},{'replay','bool'},
 {'paused','bool'},{'guard','string',16},{'profile','string',4},{'language','string',4},{'session','int'},
 {'sessionType','int'},{'clock','double'},{'player','int'},{'carCount','int'},
 -- Drapeau du joueur imposé à AC par ACAdvancedIA (panneaux du circuit) et valeur de ses feux
 {'flagOwned','bool'},{'lightsValue','int'},{'lightsReason','string',16},{'nativeFlag','int'},
 -- Panneau de l'overlay (ce que le pilote voit) : brut (decided) et affiché (kind), titres dans la langue d'ACAdvancedIA
 {'panelDecided','string',16},{'panelKind','string',16},{'panelSerial','uint'},{'panelTitle','string',64},
 {'panelShort','string',128},{'panelDouble','bool'},{'panelBlueGap','float'},{'panelNoPass','bool'},
 {'panelLit','int'},{'panelInfractions','int'},{'panelInfractionMax','int'},{'warnLeft','float'},
 -- Direction de course
 {'neutral','bool'},{'neutralMode','string',8},{'neutralFor','float'},{'escalated','bool'},{'relaunch','bool'},
 {'ending','bool'},{'endingLeft','float'},{'safetyPhase','string',12},{'safetyFailed','bool'},{'safetyCar','int'},
 {'red','bool'},{'reds','int'},{'greenLeft','float'},{'restart','bool'},{'playerRestart','bool'},
 {'standing','string',8},{'gridLit','int'},{'gridSlot','int'},{'gridGap','float'},{'gridPlaced','bool'},
 {'gridPassed','bool'},{'jumpLeft','float'},{'pitsClosed','bool'},{'slipperyLeft','float'},
 {'zone','bool'},{'zoneInside','bool'},{'zoneDouble','bool'},{'zoneCar','int'},{'zoneDistance','float'},
 {'incidentDistance','float'},{'noPass','bool'},{'yellow','bool'},{'zoneCount','int'},
 {'drsReason','string',8},{'drsLapsLeft','int'},{'pitDue','int'},{'pitRemind','bool'},
 {'slowCar','int'},{'slowGap','float'},{'meatballLeft','float'},{'damaged','bool'},
 -- Dernière annonce d'ACAdvancedIA (texte prêt dans sa langue)
 {'messageId','uint'},{'messageKind','string',16},{'messageValue','float'},{'messageExtra','float'},
 {'messageTitle','string',64},{'messageText','string',160},
 -- Delta à respecter (VSC, FCY, SC, drapeau rouge, double jaune) ; positif = assez lent
 {'deltaOn','bool'},{'deltaValue','float'},{'deltaKind','string',8},{'deltaInfraction','uint'},
 {'deltaInfractionKind','string',12},{'deltaInfractionValue','float'},{'deltaBeep','uint'},
 -- Pénalités du joueur
 {'penaltyId','uint'},{'penaltyReason','string',8},{'penaltyCount','int'},{'penaltySeconds','float'},
 {'penaltyKind','string',4},{'disqualified','bool'},{'penaltyPassed','int'},{'giveBack','int'},
 {'giveBackLeft','float'},{'redPending','bool'},{'stopPending','bool'},{'jumpPending','bool'},
 {'penaltyLimit','int'},{'nativePenalty','int'},{'nativePenaltyParam','int'},
 -- DRS, appel de phares du joueur
 {'drsBeep','uint'},{'playerDrs','int'},{'drsBlocked','bool'},{'flashId','uint'},{'flashHeard','int'},
 -- Arrêts, fenêtre, règles d'arrêt du profil
 {'pitState','string',8},{'pitClosedSerial','uint'},{'pitCsp','bool'},{'pitPosition','double'},{'pitOpen','double'},
 {'pitClose','double'},{'pitDone','int'},{'pitTotal','int'},{'mandatoryStops','int'},{'maxStintMin','float'},
 {'minPitTime','float'},{'playerStops','int'},{'playerStintFor','float'},{'pitWaived','bool'},
 -- Course
 {'raceProgress','float'},{'raceLapsLeft','float'},{'raceKnown','bool'},{'wet','bool'},{'wetSerial','uint'},
 {'finished','bool'},{'dnf','bool'},{'dq','bool'},{'finalPosition','int'},{'gridPosition','int'},
 {'correctedPosition','int'},
 -- Annonce de sanction d'une IA (panneau de l'overlay)
 {'aiSerial','uint'},{'aiCode','string',8},{'aiTitle','string',48},{'aiShort','string',128},{'aiBlack','bool'},
 -- Version 2 (AdvancedIA 1.64) : règles des sanctions de la session : avertissements de limites de piste avant la
 -- première pénalité (sanTrackWarnings, 0 = pénalité directe) et tours pour purger une pénalité aux stands
 -- (sanServeLaps ; tours restants d'une voiture = serveLaps - pendingLaps).
 {'trackWarnings','int'},{'serveLaps','int'},
}
-- Une entrée par voiture (indice d'AC), L.maxCars au plus.
L.car={
 {'valid','bool'},{'safety','bool'},{'pit','bool'},
 {'incident','bool'},{'onTrack','bool'},{'still','float'},{'halt','bool'},{'spin','bool'},{'wrong','bool'},
 {'strikes','int'},{'sanctions','int'},{'timeAdded','float'},{'pending','int'},{'pendingLaps','int'},
 {'cutLeft','float'},{'sanctionDq','bool'},{'owedTo','int'},{'flagOffences','int'},{'flagDq','bool'},
 {'planned','bool'},{'plannedStops','int'},{'nextStopLap','int'},{'stopCause','int'},{'stopLimit','int'},
 {'failure','int'},{'critical','bool'},{'called','bool'},
 {'stops','int'},{'boxed','bool'},{'stintFor','float'},
 {'mistakeId','uint'},{'mistakeKind','int'},{'overtake','bool'},
 -- Version 2 (AdvancedIA 1.64, décision du pilote du 14 novembre) : IA abandonnée (dépannée en course, garée jusqu'à la
 -- fin) ; jamais une disqualification (sanctionDq, flagDq).
 {'retired','bool'},
 -- Version 2 : raison de la dernière sanction ou pénalité émise pour cette IA (code de L.reasons), gardée jusqu'à la
 -- suivante, 0 au début de la séance ; jamais écrite pour un simple avertissement de limites de piste (code 1 réservé).
 {'lastReason','int'},
}
-- Codes des champs entiers des voitures.
L.pending={[0]='',[1]='drive',[2]='stopgo'}
L.causes={[0]='',[1]='tyres',[2]='fuel',[3]='undercut',[4]='overcut',[5]='weather',[6]='failure',[7]='cover',[8]='neutral'}
L.limits={[0]='',[1]='tyres',[2]='fuel'}
L.failures={[0]='',[1]='leak',[2]='battery',[3]='overheat',[4]='puncture'}
L.mistakes={[0]='',[1]='brake',[2]='traction'}
-- Version 2 : codes de lastReason ; 99 = autre raison (un lecteur affiche « autre » pour tout code inconnu).
L.reasons={[0]='',[1]='trackWarning',[2]='trackLimits',[3]='cut',[4]='blueFlags',[5]='contact',[6]='jumpStart',[7]='pitSpeed',
 [8]='pitExit',[9]='giveBack',[10]='flag',[11]='ignored',[12]='repeated',[13]='wrongWay'}
L.reasonOther=99
-- Code d'un nom (0 si inconnu).
function L.code(list,name)
 if name==nil or name=='' then return 0 end
 for k=1,#list do if list[k]==name then return k end end
 return 0
end
return L
