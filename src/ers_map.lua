-- SetupLab — carte du circuit et zones de déploiement de l'ERS (1.5.12, demande de Vincent du 14/11/2026 : « une map
-- qui va expliquer avec des secteurs de couleurs à quel endroit il faut pusher »). Noyau pur (D5).
--
-- Tracé : points du modèle du circuit (x, z du monde, comme la carte d'AC : z vers le bas de l'image), sous-échantillonné,
-- ramené dans un carré [0, 1] × [0, 1] en gardant les proportions. Chaque point reçoit un état :
-- 2 = déployer (part de la zone retenue par le plan, depuis son début), 1 = déploiement du profil de la voiture,
-- 0 = sans déploiement (récupération, lever de pied, freinage).

local M = {}

local ceil, max, min = math.ceil, math.max, math.min

M.DEPLOY, M.PROFILE, M.NONE = 2, 1, 0
M.MAX_POINTS = 180

-- État de l'abscisse s (m) pour les zones { s0, s1, fraction?, profile? } d'un tour de longueur length (zones qui
-- franchissent la ligne : s1 < s0).
function M.stateAt(zones, s, length)
  for i = 1, #zones do
    local z = zones[i]
    local s0, s1 = z.s0, z.s1
    if s0 and s1 then
      local span = s1 - s0
      if span < 0 then span = span + length end
      local d = s - s0
      if d < 0 then d = d + length end
      if d <= span then
        if z.profile then return M.PROFILE end
        local f = z.fraction or 1
        if d <= span * f then return M.DEPLOY end
        return M.NONE
      end
    end
  end
  return M.NONE
end

-- Carte d'un modèle de circuit (t : { n, x, z, s, length }) et des zones d'un plan ERS. Renvoie
-- { n, x, y, state, aspect, deployed, closed } (x, y dans [0, 1], aspect = hauteur / largeur), ou nil et la raison.
function M.build(t, zones, closed)
  if type(t) ~= 'table' or type(t.x) ~= 'table' or type(t.z) ~= 'table' or type(t.s) ~= 'table' then
    return nil, 'tracé du circuit indisponible'
  end
  local n = t.n or #t.x
  if n < 8 or not (t.length and t.length > 0) then return nil, 'tracé du circuit trop court' end
  if type(zones) ~= 'table' or #zones == 0 then return nil, 'aucune zone de déploiement' end
  for i = 1, #zones do
    local z = zones[i]
    if not (z.s0 and z.s1) or z.s0 < -1 or z.s1 < -1 or z.s0 > t.length + 1 or z.s1 > t.length + 1 then
      return nil, 'zones calculées sur un autre tracé'
    end
  end
  local step = max(1, ceil(n / M.MAX_POINTS))
  local out = { x = {}, y = {}, state = {}, n = 0, closed = closed ~= false, deployed = 0 }
  local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
  for k = 1, n, step do
    local x, y = t.x[k], t.z[k]
    if x == nil or y == nil then return nil, 'tracé du circuit incomplet' end
    local j = out.n + 1
    out.x[j], out.y[j], out.n = x, y, j
    out.state[j] = M.stateAt(zones, t.s[k], t.length)
    if out.state[j] == M.DEPLOY then out.deployed = out.deployed + 1 end
    x0, x1, y0, y1 = min(x0, x), max(x1, x), min(y0, y), max(y1, y)
  end
  local span = max(x1 - x0, y1 - y0)
  if not (span > 0) then return nil, 'tracé du circuit dégénéré' end
  for j = 1, out.n do
    out.x[j] = (out.x[j] - x0) / span
    out.y[j] = (out.y[j] - y0) / span
  end
  out.width, out.height = (x1 - x0) / span, (y1 - y0) / span
  out.aspect = out.height / max(out.width, 1e-6)
  -- sens de marche : du premier point vers le suivant
  out.dirX, out.dirY = out.x[2] - out.x[1], out.y[2] - out.y[1]
  return out
end

return M
