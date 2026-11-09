-- Contrôles du modèle (relecture du 09/11/2026) : vitesse de pointe au limiteur, freinage combiné, réglages verrouillés,
-- optimiseur au-delà des dimensions de Halton.
local T = require('t')
local Util = require('src/util')
local Datasource = require('src/datasource')
local CarModel = require('src/car_model')
local Space = require('src/setup_space')
local Optimizer = require('src/optimizer')
local Fake = require('fakehost')

local SYNC = Util.syncContext()
local tests = {}

local function tyre(mu)
  return { radius = 0.3, dyRef = mu, dxRef = mu, dcamber0 = 0, dcamber1 = 0, pressureDGain = 0, rr0 = 0, rr1 = 0,
    deformCamber = 0, pressureStatic = 26 }
end

-- Voiture à couple constant (400 N·m), un rapport (4), rayon 0,3 m, limiteur choisi, traînée cd·1 m².
local function car(limiter, cd)
  local base = CarModel.fromParams({
    massDry = 1000, cgFront = 0.5, wheelbase = 2.6, trackF = 1.6, trackR = 1.6, cgHeight = 0.3,
    compounds = { { index = 0, name = 't', front = tyre(1.2), rear = tyre(1.2) } },
    torque = Util.lutNew({ 0, 20000 }, { 400, 400 }), limiter = limiter, rpmMin = 250, gears = { 1 }, final = 4,
    shiftUpTime = 0, brakeFront = 0.6, fuelDefault = 0,
    wings = { { index = 0, name = 'BODY', area = 1, z = 0, cd = Util.lutNew({ -10, 10 }, { cd, cd }), clGain = 1, cdGain = 1,
      angle = 0 } },
  })
  return base, CarModel.defaultSetup(base)
end

-- R1 : vitesse de pointe limitée par le limiteur : la dichotomie interpole la force de l'enveloppe entre un
-- point sous le limiteur et un point au-delà (force 0) : la pointe tombe sous la vitesse au limiteur alors que la
-- force y dépasse encore la traînée.
tests['MC01 vitesse de pointe au limiteur : jamais sous la vitesse au limiteur si la force y dépasse la traînée'] = function()
  local vmax = 81.9
  local limiter = vmax * 4 / 0.3 * 60 / (2 * math.pi)
  local base, setup = car(limiter, 1.0)
  local eff = assert(CarModel.configure(base, setup, { airTemp = 20 }))
  local v = eff.gearVmax[1]
  local force = 400 * 4 * 0.9 / 0.3
  local drag = 0.5 * eff.rho * v * v * 1.0
  T.ok(force > drag + 500, 'force ' .. force .. ' > traînée ' .. drag .. ' au limiteur')
  T.near(v, vmax, 1e-6)
  T.ok(eff.topSpeed >= v - 0.05, 'pointe ' .. eff.topSpeed .. ' contre vitesse au limiteur ' .. v)
end

-- R2 : la recherche de Halton n'a que M.MAX_DIMS bases ; M.MAX_DIMS n'est lu nulle part.
tests['MC02 optimiseur : plus de variables que de bases de Halton, sans plantage'] = function()
  local dims = {}
  for d = 1, Optimizer.MAX_DIMS + 1 do dims[d] = { key = 'v' .. d, lo = -2, hi = 2 } end
  local problem = { dims = dims, budget = 200, evaluate = function(x) return x[1] * x[1] end }
  local ok, err = pcall(Optimizer.run, problem, { tick = function() end })
  T.ok(ok, tostring(err))
end

-- R3 : un réglage verrouillé (D20) n'entre pas dans l'espace ; le modèle simule alors la valeur d'usine du
-- fichier (brakes.ini) au lieu de la valeur montée dans la voiture.
tests['MC03 réglage verrouillé : sa valeur montée sert au modèle'] = function()
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
  local c = Datasource.readCar(h, 0, SYNC)
  local s = Datasource.readSetup(h, SYNC)
  local base = CarModel.build(c, nil)
  local spinners, lockedValue = {}, nil
  for i, sp in ipairs(s.spinners) do
    spinners[i] = sp
    if sp.name == 'FRONT_BIAS' then
      lockedValue = sp.min
      spinners[i] = setmetatable({ readOnly = true, value = sp.min }, { __index = sp })
    end
  end
  local space = Space.build({ setupIni = c.ini['setup.ini'], spinners = spinners, ratios = c.ratios })
  local setup = Space.apply(space, CarModel.defaultSetup(base), {})
  T.ok(lockedValue ~= nil)
  T.near(setup.brakeBias, lockedValue / 100, 1e-6, 'répartition simulée ' .. setup.brakeBias .. ', montée '
    .. lockedValue / 100)
end

-- Freinage combiné : l'ellipse d'adhérence réduit l'adhérence en virage, jamais le couple des freins. Les tables de
-- freinage sont celles de l'adhérence seule ; la puissance de freinage borne à part (eff.brakeForceMax).
tests['MC04 freinage : tables de l\'adhérence seule, couple des freins borné à part'] = function()
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
  local base = CarModel.build(Datasource.readCar(h, 0, SYNC), nil)
  local strong, weak = CarModel.defaultSetup(base), CarModel.defaultSetup(base)
  weak.brakePower = 0.4
  local a = assert(CarModel.configure(base, strong, { airTemp = 20 }))
  local brakeA, forceA = a.brake[2][10], a.brakeForceMax
  local b = assert(CarModel.configure(base, weak, { airTemp = 20 }))
  T.ok(Util.isFinite(forceA) and forceA < math.huge, 'couple des freins connu')
  T.near(b.brake[2][10], brakeA, 1e-9, 'adhérence seule : même table')
  T.near(b.brakeForceMax, forceA * 0.4, 1e-6 * forceA, 'couple des freins proportionnel')
end

return tests
