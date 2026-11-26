## The society model's pure formulas (docs/society.md): one place for the arithmetic the
## calculator (tools/society_calc.gd) and, later, the game's sim.soc both use, so the two
## can't drift apart. Static, no state, no RNG.
extends RefCounted

## Benefit of coverage c: concave, 0 at 0, 1 at 1 and above (model §4).
static func benefit(c: float) -> float:
	if c >= 1.0: return 1.0
	if c <= 0.0: return 0.0
	return 1.0 - (1.0 - c) * (1.0 - c)

## The actual rise in benefit from adding supply s to a need of demand d at coverage c
## (model §8): bounded by 1 - B(c), and 0 once c >= 1 or with nothing to add.
static func gain(c: float, s: float, d: float) -> float:
	if d <= 0.0 or s <= 0.0 or c >= 1.0: return 0.0
	return benefit(minf(1.0, c + s / d)) - benefit(c)

## Demand that grows faster than people (model §6): a × x × (x / x0)^k.
static func scaled(a: float, x: float, x0: float, k: float) -> float:
	if x <= 0.0: return 0.0
	return a * x * pow(x / maxf(1e-6, x0), k)

## Order's demand (model §6): coordination a_c × n once a Steward exists, plus disputes
## a_d × max(0, n - n0) × (n / n0)^k past the face-to-face limit. In units of order-work a
## day at an informal keeper's full span.
static func order_demand(n: float, a_c: float, a_d: float, n0: float, k: float, steward: bool) -> float:
	var coord := a_c * n if steward else 0.0
	var disputes := a_d * maxf(0.0, n - n0) * pow(maxf(n, 1.0) / n0, k)
	return coord + disputes

## A keeper's span (model §6): an informal keeper's shrinks past n1 (n1 / n); an
## institution's doesn't, and the Code multiplies it.
static func order_span(n: float, n1: float, institutions: bool, code_mult: float) -> float:
	if institutions: return code_mult
	return 1.0 if n <= n1 else n1 / n

## Food a day for one person (model §2): the hunger of a day at rest plus the walk's,
## filled `fill` hunger per `meal` food. hunger_day already carries the season.
static func food_per_day(hunger_day: float, walk_paces: float, walk_hunger: float, meal: float, fill: float) -> float:
	return (hunger_day + walk_paces * walk_hunger) * meal / maxf(1e-6, fill)

## The share of hands food takes at a given R (model §3.2): (1 + m) / R.
static func food_share(r: float, m: float) -> float:
	return (1.0 + m) / maxf(1e-6, r)

## Output of n hands on a land-limited source (model §3.2): f a day each, at most y a day
## in all, with diminishing returns: y × (1 - e^(-n f / y)). y <= 0 = no land limit.
static func land_output(n: float, f: float, y: float) -> float:
	if n <= 0.0 or f <= 0.0: return 0.0
	if y <= 0.0: return n * f
	return y * (1.0 - exp(-n * f / y))

## What one more hand adds on that source (the derivative, model §3.2).
static func land_marginal(n: float, f: float, y: float) -> float:
	if f <= 0.0: return 0.0
	if y <= 0.0: return f
	return f * exp(-n * f / y)

## A trade's payback (model §8): hands freed elsewhere per hand it takes.
static func payback(freed: float, taken: float) -> float:
	return freed / taken if taken > 0.0 else 0.0

## The product of the productivity factors (model §3: the budget).
static func factor_product(f: Dictionary) -> float:
	var p := 1.0
	for k in f: p *= float(f[k])
	return p
