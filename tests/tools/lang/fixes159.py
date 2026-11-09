# Bêta 1.5.9 (09/11/2026) : chargement sur la grille, temps d'AC, mémoire en temps réels, pneus de qualification.
EN = {
    # chargement sur la grille avant le départ
    'sur la grille': 'on the grid',
    'sur la grille, avant le départ': 'on the grid, before the start',
    'sur la grille, avant le départ (oui)': 'on the grid, before the start (yes)',
    'sur la grille, avant le départ (non)': 'on the grid, before the start (no)',
    'setup non modifiable maintenant : ouvrir le menu de setup sur la grille, avant le départ':
        'setup not editable now: open the setup menu on the grid, before the start',
    # temps d'AC et tour propre
    'propre %s': 'clean %s',
    'aucun tour propre': 'no clean lap',
    "Votre meilleur tour de la séance avec cette version (chrono d'AC)": 'Your best lap of the session with this version (AC timing)',
    "Votre meilleur tour de la séance avec le setup actuel (chrono d'AC).":
        'Your best lap of the session with the current setup (AC timing).',
    'Avec le setup actuel : %s.': 'With the current setup: %s.',
    "hors analyse (%s) · compté au chrono d'AC": 'left out of the analysis (%s) · counted by AC timing',
    "Dernier tour %s : hors analyse (%s) · compté au chrono d'AC": 'Last lap %s: left out of the analysis (%s) · counted by AC timing',
    "%s — dernier tour hors analyse : %s · compté au chrono d'AC": '%s — last lap left out of the analysis: %s · counted by AC timing',
    'Meilleur · séance': 'Best · session',
    'Meilleur (séance)': 'Best (session)',
    '%s (AC · aucun tour propre)': '%s (AC · no clean lap)',
    '%s (AC · propre %s, %s tour%s)': '{1} (AC · clean {2}, {3} lap{4})',
    # mémoire du circuit
    'temps simulé · aucun tour mesuré': 'simulated time · no lap measured',
    'meilleur · toutes séances': 'best · all sessions',
    'Règle des pneus de qualification non appliquée (aucun pneu tendre reconnu) : %s':
        'Qualifying tyre rule not applied (no soft tyre recognised): %s',
    # pneus de qualification
    'règle de qualification : le plus tendre': 'qualifying rule: the softest',
    'qualif · le plus tendre': 'qualifying · the softest',
    'SUR LA GRILLE': 'ON THE GRID',
    'GRILLE': 'GRID',
}
EN.update({
    # journal
    "rejeté (%s) ; compté dans vos temps d'AC": "rejected (%s); counted in your AC times",
    "Meilleur tour d'AC %s s non compté dans vos temps (%s)": "AC best lap %s s not counted in your times (%s)",
    "Meilleur tour d'AC de la séance : %s s": "AC best lap of the session: %s s",
    "Meilleur tour d'AC de la séance : %s s (un autre tour que celui-ci)":
        "AC best lap of the session: %s s (another lap than this one)",
    'Pneus de qualification : %s (le plus tendre de la gamme)': 'Qualifying tyres: %s (the softest of the range)',
    '%s État : au stand %s, voie des stands %s, menu de setup %s, séance commencée %s, séance de course %s, vitesse %s km/h':
        '%s State: in the pits %s, pit lane %s, setup menu %s, session started %s, race session %s, speed %s km/h',
    "Sur la grille avant le départ, menu de setup ouvert : « Charger » pour la mettre dans la voiture ; l'affinage repartira d'elle.":
        'On the grid before the start, setup menu open: "Load" to put it in the car; the refinement will carry on from it.',
})
EN.update({
    'non vérifiable : crans déduits de setup.ini (réglages verrouillés par la série et setup par défaut de la voiture inconnus)':
        "not verifiable: settings deduced from setup.ini (settings locked by the series and the car's default setup unknown)",
    "Meilleur tour d'AC %s s : tour non enregistré par SetupLab": 'AC best lap %s s: lap not recorded by SetupLab',
    'Chargement refusé.': 'Load refused.',
    "Départ : setup par défaut de la voiture, écrit dans %s ; il va dans la voiture (%s, menu de setup ouvert) et l'affinage %s partira de lui.":
        "Start: the car's default setup, written to {1}; it goes into the car ({2}, setup menu open) and the {3} refinement will start from it.",
    " ; elle va dans la voiture (%s, menu de setup ouvert) et l'affinage partira d'elle.":
        '; it goes into the car (%s, setup menu open) and the refinement will start from it.',
    "Départ : votre référence %s ; elle va dans la voiture (%s, menu de setup ouvert) et l'affinage partira d'elle.":
        'Start: your reference %s; it goes into the car (%s, setup menu open) and the refinement will start from it.',
})
