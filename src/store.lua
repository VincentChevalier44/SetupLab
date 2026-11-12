-- SetupLab — persistance (§13). Module d'E/S : l'hôte est injecté par la colle.
--
-- Une seule valeur ac.storage (« setuplab:data », écrite par CSP quelques secondes après chaque
-- changement, dans un fichier de configuration de Documents\Assetto Corsa\cfg\extension\state\lua).
-- Format texte d'une seule ligne, sans caractère de contrôle (la valeur est une ligne de ce fichier),
-- relu sans jamais exécuter de code (§16.2) :
--   setuplab-store <version>|<clé d'entrée>#<champ>=<valeur>|…
-- Valeurs : nombre, true/false, ou chaîne courte « s:… » au jeu de caractères restreint. Chaque genre
-- d'entrée a son schéma (champs, types, bornes) : tout champ inconnu, hors bornes ou mal formé est
-- ignoré à la lecture comme à l'écriture (aucune confiance dans le contenu stocké). Taille bornée,
-- purge des entrées les moins récemment utilisées. Version inconnue : contenu ignoré, signalé.

local Util = require('src/util')
local Config = require('src/config')
local K = Config.K

local M = {}

local get, call = Util.get, Util.call

M.VERSION = Config.schemaVersion
M.KEY = 'setuplab:data'

-- Schémas par genre d'entrée (préfixe de la clé avant le premier « : ») : champ -> { type, min, max }.
-- Bornes celles du producteur (D11) : facteurs dans celles de la calibration (§9.2), rugosité plausible.
local function factor(key) return { 'number', K.calibBounds[key][1], K.calibBounds[key][2] } end
local STAMP = { 'number', 0, 1e11 }
local ROUGH = { 'number', 0, K.roughMaxG0 }
local HASH = { 'number', 0, Util.HASH_MOD }
local FLAG = { 'boolean' }
M.SCHEMAS = {
  cal = {
    mu = factor('mu'), power = factor('power'), drag = factor('drag'), lift = factor('lift'), brake = factor('brake'),
    id_mu = FLAG, id_power = FLAG, id_drag = FLAG, id_lift = FLAG, id_brake = FLAG,
    airTemp = { 'number', -40, 70 }, roadTemp = { 'number', -40, 90 }, laps = { 'number', 1, 100 },
    data = HASH, model = { 'number', 0, 1e6 }, stamp = STAMP,
  },
  rough = { G0 = ROUGH, front = ROUGH, rear = ROUGH, speed = { 'number', 0, 150 }, data = HASH, model = { 'number', 0, 1e6 },
    stamp = STAMP },
  -- calibration sur piste mouillée (D16 amendé) : mêmes champs, clé à part (la clé du sec ne change pas)
  calwet = {
    mu = factor('mu'), power = factor('power'), drag = factor('drag'), lift = factor('lift'), brake = factor('brake'),
    id_mu = FLAG, id_power = FLAG, id_drag = FLAG, id_lift = FLAG, id_brake = FLAG,
    airTemp = { 'number', -40, 70 }, roadTemp = { 'number', -40, 90 }, laps = { 'number', 1, 100 },
    data = HASH, model = { 'number', 0, 1e6 }, stamp = STAMP,
  },
  last = { file = { 'string' }, gain = { 'number', -120, 120 }, time = { 'number', 0, 1e4 }, stamp = STAMP },
  -- mémoire du circuit (décision de Vincent du 21/10/2026) : setup validé d'une séance et d'un état de piste,
  -- désigné par son nom de fichier et l'empreinte de son contenu ; figé (cadenas) ou non
  mem = { file = { 'string' }, hash = HASH, version = { 'number', 0, 1000 }, gain = { 'number', -120, 120 },
    time = { 'number', 0, 1e4 }, locked = FLAG, stamp = STAMP,
    -- vos temps réels avec ce setup (09/11/2026) : meilleur tour d'AC (tour rapide), moyenne et nombre de tours (course)
    best = { 'number', 0, 1e4 }, mean = { 'number', 0, 1e4 }, laps = { 'number', 0, 1e5 } },
  -- versions de qualification validées (1.5.3, décision de Vincent du 02/11/2026 : la course part de l'une d'elles,
  -- d'un lancement d'AC à l'autre) ; clé : voiture, circuit, disposition, « qualif », empreinte du fichier
  ver = { file = { 'string' }, hash = HASH, version = { 'number', 0, 1000 }, stamp = STAMP },
  -- nombre de tours de la course saisi (décision de Vincent du 26/10/2026), gardé par voiture et circuit
  rlaps = { laps = { 'number', 1, 500 }, stamp = STAMP },
}

-- Morceau de clé : identifiant sûr en UTF-8 bien formé (la valeur stockée est une ligne de texte), ou entier.
local function keyPart(text)
  return (Util.isSafeId(text) and Util.isUtf8(text)) or text:match('^%-?%d+$') ~= nil
end

-- Clé d'entrée : genre puis identifiants sûrs (voiture, circuit, composé…), séparés par « : ». Apostrophe, guillemet et
-- point-virgule remplacés par « _ » : CSP écrit la valeur entre apostrophes dans son fichier INI, l'un d'eux pourrait
-- couper toute la ligne à la relecture (dossier de mod « …_'22 »).
function M.entryKey(kind, ...)
  local parts = { kind }
  for _, id in ipairs({ ... }) do
    local text = tostring(id):gsub("['\";]", '_')
    if not keyPart(text) then return nil end
    parts[#parts + 1] = text
  end
  return table.concat(parts, ':')
end

-- Clé relue valide : celle que M.entryKey forme (genre, puis identifiants sûrs ou entiers séparés par « : »).
local function validKey(key)
  local first = true
  for part in (key .. ':'):gmatch('([^:]*):') do
    if first then
      if not part:match('^[%a_]+$') then return false end
      first = false
    elseif not keyPart(part) then
      return false
    end
  end
  return true
end

local function kindOf(key)
  local kind = key:match('^([%a_]+)')
  -- une seule entrée de réglages : « settings:… » n'est pas une clé (jamais lue, jamais purgée)
  if kind == 'settings' and key ~= 'settings' then return nil end
  return kind
end

-- Valeur validée selon son schéma (nil si refusée).
local function validField(kind, field, value)
  if kind == 'settings' then
    local editable = false
    for _, key in ipairs(Config.EDITABLE) do editable = editable or key == field end
    if not editable then return nil end
    for _, def in ipairs(Config.settings) do
      if def.key == field then
        local ok, fix = Config.validateOne(def, value)
        if fix == nil then return ok end
        return nil
      end
    end
    return nil
  end
  local schema = M.SCHEMAS[kind]
  local rule = schema and schema[field]
  if rule == nil then return nil end
  if rule[1] == 'number' then
    if not Util.isFinite(value) or value < rule[2] or value > rule[3] then return nil end
    return value
  end
  if rule[1] == 'boolean' then
    if type(value) ~= 'boolean' then return nil end
    return value
  end
  if type(value) ~= 'string' or #value > K.storeMaxString or not value:match('^[%w_%-%. ]*$') then return nil end
  return value
end

-- Nombres écrits court (le stockage tient en une ligne de 64 Ko au plus) : entiers sans décimale, autres à 9 chiffres
-- significatifs (températures, facteurs, temps au tour : bien plus fin que leur précision réelle).
local function encode(value)
  if type(value) == 'boolean' then return value and 'true' or 'false' end
  if type(value) == 'number' then
    if value == math.floor(value) and math.abs(value) < 2 ^ 53 then return string.format('%d', value) end
    return string.format('%.9g', value)
  end
  return 's:' .. value
end

local function decode(text)
  if text == 'true' then return true end
  if text == 'false' then return false end
  local s = text:match('^s:(.*)$')
  if s then return s end
  return Util.parseNumber(text)
end

-- Texte d'un ensemble d'entrées { [clé] = { champ = valeur } } (ordre stable).
function M.serialize(entries)
  local keys = {}
  for key in pairs(entries) do keys[#keys + 1] = key end
  table.sort(keys)
  local lines = { 'setuplab-store ' .. M.VERSION }
  for _, key in ipairs(keys) do
    local fields = {}
    for field in pairs(entries[key]) do fields[#fields + 1] = field end
    table.sort(fields)
    for _, field in ipairs(fields) do lines[#lines + 1] = key .. '#' .. field .. '=' .. encode(entries[key][field]) end
  end
  return table.concat(lines, '|')
end

-- Entrées relues d'un texte stocké, chaque champ validé ; renvoie entries, raison (version inconnue,
-- lignes rejetées).
function M.parse(text)
  local entries, rejected = {}, 0
  if type(text) ~= 'string' or text == '' then return entries, nil end
  if #text > K.storeMaxBytes then return entries, 'contenu trop volumineux : ignoré' end
  local version = tonumber(text:match('^setuplab%-store (%d+)'))
  if version == nil then return entries, 'en-tête absent : contenu ignoré' end
  if version > M.VERSION then return entries, 'version ' .. version .. ' plus récente que l\'app : contenu ignoré' end
  if version < 1 then return entries, 'version ' .. version .. ' inconnue : contenu ignoré' end
  local count = 0
  for line in text:gmatch('[^|]+') do
    count = count + 1
    if count > 1 then
      -- clé : identifiants sûrs (Util.isSafeId : dossiers de mods avec espaces, accents, parenthèses… jamais « # | = »)
      local key, field, value = line:match('^([^#|=%c]+)#([%w_]+)=([^%c]*)$')
      local kind = key and validKey(key) and kindOf(key)
      -- pas de « a and b or nil » : false est une valeur valide
      local valid = nil
      if kind then valid = validField(kind, field, decode(value)) end
      if valid ~= nil then
        entries[key] = entries[key] or {}
        entries[key][field] = valid
      else
        rejected = rejected + 1
      end
    end
  end
  return entries, rejected > 0 and (rejected .. ' ligne(s) rejetée(s)') or nil
end

-- Ouvre le stockage. Renvoie { entries, value (ac.StoredValue), status, reason }.
function M.open(host)
  local store = { entries = {}, status = 'indisponible', dirty = false }
  local ok, value = call(get(host.ac, 'storage'), M.KEY, '')
  if not ok or value == nil or get(value, 'get') == nil then
    store.reason = ok and 'ac.storage sans valeur' or tostring(value)
    return store
  end
  store.value = value
  local okGet, text = call(function() return value:get() end)
  if not okGet then
    store.reason = tostring(text)
    return store
  end
  store.entries, store.reason = M.parse(text)
  store.status = 'ouvert'
  -- entrées relues d'une séance précédente : preuve que la valeur a fait l'aller-retour sur disque
  store.loaded = 0
  for _ in pairs(store.entries) do store.loaded = store.loaded + 1 end
  return store
end

-- Horodatage d'une entrée : seconde entière (un nombre court dans le texte stocké).
local function stampOf(kind, now)
  local stamp = kind and M.SCHEMAS[kind] and M.SCHEMAS[kind].stamp and validField(kind, 'stamp', now) or nil
  return stamp and math.floor(stamp) or nil
end

-- Entrée validée (copie), ou nil ; marque l'entrée comme utilisée. La date d'usage seule ne déclenche pas d'écriture
-- (elle part avec la prochaine) : une relecture ne coûte pas une sérialisation complète.
function M.get(store, key, now)
  local entry = key and store.entries[key]
  if entry == nil then return nil end
  local stamp = stampOf(kindOf(key), now)
  if stamp then entry.stamp = stamp end
  local out = {}
  for field, value in pairs(entry) do out[field] = value end
  return out
end

-- Enregistre une entrée (champs validés un par un, les autres ignorés) ; purge si trop gros.
function M.put(store, key, fields, now)
  if key == nil then return false end
  local kind = kindOf(key)
  local entry, count = {}, 0
  for field, value in pairs(fields) do
    local valid = validField(kind, field, value)
    if valid ~= nil and field ~= 'stamp' then
      entry[field] = valid
      count = count + 1
    end
  end
  if count == 0 then return false end
  entry.stamp = stampOf(kind, now)
  store.entries[key] = entry
  -- en mémoire seulement : sérialisation et purge au flush (1 Hz), pas à chaque frame d'un curseur
  store.dirty = true
  return true
end

-- Retire une entrée (setup écarté qui était en mémoire).
function M.remove(store, key)
  if key == nil or store.entries[key] == nil then return false end
  store.entries[key] = nil
  store.dirty = true
  return true
end

-- Purge : tant que le texte dépasse K.storeMaxBytes, une entrée part, d'abord ce qui se recalcule (rugosité, puis
-- calibrations), puis les derniers setups et les tours de course saisis, puis les versions de qualification validées et
-- la mémoire du circuit ; à rang égal, la moins récemment utilisée (une entrée sans date compte comme la plus ancienne).
-- Un setup figé de la mémoire du circuit ne part qu'en dernier (décision de Vincent du 21/10/2026 : proposé à chaque
-- visite). Seuls les réglages (une entrée bornée) ne partent jamais : le texte écrit tient sous la limite et sera relu à
-- la séance suivante. Les clés retirées sont rangées dans store.purged (journal de la colle).
M.PURGE_RANK = { rough = 1, cal = 2, calwet = 2, last = 3, rlaps = 3, ver = 4, mem = 5 }

local function rankOf(key, entry)
  local kind = kindOf(key)
  if kind == 'settings' or kind == nil then return nil end
  if kind == 'mem' and entry.locked == true then return 6 end
  return M.PURGE_RANK[kind] or 1
end

function M.purge(store)
  local text = M.serialize(store.entries)
  while #text > K.storeMaxBytes do
    local victim, bestRank, bestStamp = nil, math.huge, math.huge
    for key, entry in pairs(store.entries) do
      local rank = rankOf(key, entry)
      local stamp = entry.stamp or 0
      if rank and (rank < bestRank or (rank == bestRank and (stamp < bestStamp
          or (stamp == bestStamp and key < victim)))) then
        victim, bestRank, bestStamp = key, rank, stamp
      end
    end
    if victim == nil then break end
    store.entries[victim] = nil
    store.purged = store.purged or {}
    store.purged[#store.purged + 1] = victim
    text = M.serialize(store.entries)
  end
  return text
end

-- Écrit les entrées (CSP écrit sur disque quelques secondes plus tard). Renvoie vrai si écrit.
function M.flush(store)
  if not (store.dirty and store.value) then return false end
  local text = M.purge(store)
  local ok, why = call(function() store.value:set(text) end)
  if not ok then
    store.reason = tostring(why)
    return false
  end
  store.dirty = false
  return true
end

return M
