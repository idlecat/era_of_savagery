# Product Requirements Document (PRD): *Era of Savagery: Clan Chronicles*

**Document Version**: v2.0 (Includes "Task Contract & Node-Triggered LLM Architecture")  
**Genre**: Pause-and-Play Real-Time Strategy (RTS) / Tribe Simulation & Management / Individual RPG Progression  
**Core Inspirations**: *Jurassic War* (individual unit experience & progression), *Civilization* series (macro tech tree & historical/mythological branching choices), *RimWorld* (semi-autonomous AI & individual emergent storytelling)

---

## 1. Product Overview & Core Experience

### 1.1 Setting & Background
Set in the dawn of human civilization—a brutal, untamed prehistoric era where colossal beasts roam the land, the environment is unforgiving, and legends of ancient totems and deities are passed down through oral tradition. The player assumes the role of the Great Chieftain / Totem Will of a primitive tribe, leading dozens of unique tribespeople—each with distinct personalities, capabilities, and personal histories—from rubbing sticks to make fire and hunting-gathering to unlocking tribal wisdom, taming prehistoric megafauna, surviving cataclysmic floods and deep freezes, and forging an ancient mythological civilization.

### 1.2 Core Gameplay Loop
1. **Micro-Management & Survival (Early Game)**: Manually assign individual tribespeople to forage, hunt, chop wood, and build shelters to secure food and basic safety.
2. **Individual Experience & Specialization (Throughout the Game)**: Every completed task (hunting, building, combat, shamanic rituals) grants experience in that specific domain, improving efficiency and success rates, unlocking specialized traits, and recording events into the unit's personal "Memory Archive."
3. **Delegated Governance & Semi-Autonomous Control (Mid-to-Late Game Core Differentiator)**:
   - **Direct Micro-Management**: Directly control specific heroes or squads for tactical combat, exploration, or emergency construction.
   - **Task Contracts & Semi-Autonomous Goals (Node-Triggered LLM)**: Assign a macro objective to a chosen tribesperson (e.g., *"Establish a new settlement across the river"*). This triggers that individual's **LLM Persona Core**, which negotiates details with the player based on their personality, stats, and past memories, generating a structured execution blueprint (JSON). Once confirmed, a deterministic state machine executes the plan autonomously with **zero LLM calls during normal execution**, re-awakening the LLM only if an unexpected interruption occurs (e.g., enemy raid, natural disaster).
   - **Vice-Chieftain Full Auto-Delegation**: Appoint high-prestige or high-intelligence tribespeople as "Vice-Chieftains" (Steward, High Shaman, War Chief) to autonomously manage routine production and expansion according to high-level policy directives.
   - **Major Decision Interventions**: When critical milestones occur (e.g., overpopulation requiring migration, rival tribe invasions, mythological disasters), the game automatically pauses and presents *Civilization*-style branching dilemmas.

---

## 2. Core System Design

### 2.1 Three-Tier Control Hierarchy
| Control Tier | Trigger Mechanism | Ideal Use Cases | Player Experience |
| :--- | :--- | :--- | :--- |
| **Tier 1: Direct Micro (Manual)** | Select units + right-click commands | Hunting apex predators, tactical combat positioning, emergency wall repairs | Captures the classic *Jurassic War* thrill of high-stakes individual unit control |
| **Tier 2: Task Contracts (Semi-Auto + Node LLM)** | Assign a leader to a strategic goal $ightarrow$ LLM negotiates blueprint $ightarrow$ State machine executes | *"Build an outpost across the river"*, *"Form a hunting expedition"* | Combines immersive character roleplay with reliable, zero-latency AI execution |
| **Tier 3: Vice-Chieftain Delegation (Auto-Delegate)** | Appoint an NPC as Vice-Chieftain with policy presets | Balanced growth, military buildup, religious focus | Delivers a ruler's macro perspective, freeing the player for diplomacy, exploration, and major choices |

### 2.2 Core Innovation: Individualized LLM Personas & the "Task Contract" Mechanism

To ensure **every tribesperson feels alive and natural** while maintaining **60 FPS real-time performance and minimal API/compute overhead**, the system uses a layered asynchronous architecture: **Node-Triggered LLM Planning + Deterministic Behavior Tree Execution**. **Real-time frame-by-frame LLM calls are strictly prohibited.**

#### 2.2.1 Character Persona & Memory Archive
Each tribesperson maintains a lightweight profile injected as context when their LLM node is awakened:
- **Personality Traits**: e.g., *Cautious & Pragmatic, Belligerent & Impulsive, Gluttonous & Agrarian, Devout & Mystical, Slightly Lazy*. Traits shape both dialogue tone and structural priorities in their proposed blueprints.
- **Capability Profile (Stats & Skills)**: Current unit level, four specialization skill levels, health/stamina status.
- **Memory Stream**: An objective log automatically recorded by the engine (retaining the ~10 most impactful recent events, such as *"Critically wounded by a saber-toothed tiger on the east bank on Day 3"* or *"Led flood-levee reinforcement during the Great Flood"*).

#### 2.2.2 Four-Phase Task Contract Lifecycle (Example: *"Build a Settlement Across the River"*)
1. **Phase 1: Assignment & Negotiation (Triggers LLM — Once)**
   - The player selects a unit as expedition leader and issues a macro directive (e.g., *"Establish a settlement across the river"*). The game pauses and opens a negotiation dialogue.
   - The client injects the **Leader's Profile (stats + traits + memory stream)** and **Target Environment Data (resource nodes, predator threats, tribe stockpiles)** into the prompt.
   - **Personalized Proposal Generation**:
     - If **Cautious Master Builder [Panshi]** is chosen: *"Great Chieftain, the east bank has fine timber, but there are beast tracks in the tall grass. Based on my experience building levees, I suggest we start small: 2 huts for 6 people, a wooden palisade first for safety, then a fishing dock. Does that sound wise?"*
     - If **Belligerent Warrior [Alie]** is chosen: *"Leave the frontier to me! Forget slow walls—I'll take two brothers across, light a grand bonfire, build 3 large huts for 10 people, and put a weapon rack right in the center. If any beast comes, we crush it!"*
   - Once the player approves or adjusts parameters (population capacity, focus on farming/fishing/defense), the LLM outputs a **Structured Task Contract (JSON Blueprint)**.
2. **Phase 2: Conversion to Deterministic Behavior Tree (Zero LLM Calls)**
   - The engine parses the JSON blueprint into an actionable task queue with explicit abort conditions:
     ```json
     {
       "plan_id": "east_river_outpost_01",
       "leader_id": "unit_3",
       "crew_size": 3,
       "capacity_target": 6,
       "focus": "fishery_and_defense",
       "steps": [
         {"action": "gather_wood", "target_amount": 60, "location": "east_forest"},
         {"action": "build", "structure": "wooden_palisade", "priority": 1},
         {"action": "build", "structure": "fishing_dock", "priority": 2},
         {"action": "build", "structure": "hut", "count": 2, "capacity": 6}
       ],
       "abort_conditions": ["enemy_attack", "hp_below_30%", "natural_disaster"]
     }
     ```
   - Once finalized, **the LLM connection is closed**. The leader gathers idle helpers and executes the steps sequentially without further AI calls.
3. **Phase 3: Routine Execution & Experience/Memory Accumulation (Pure Local Logic)**
   - Completing each step grants specialization XP (`+EXP`) to participating units and logs objective milestones into their local memory streams.
   - Under normal conditions, zero LLM calls occur until the entire settlement is completed.
4. **Phase 4: Unexpected Interruption & Emergency Awakening (Triggers LLM — Exceptions Only)**
   - If an `abort_condition` is triggered (e.g., rival tribe ambush, megafauna attack, flash flood/blizzard, or leader critically injured), execution pauses and **re-awakens the LLM**.
   - Given current progress (e.g., *"55% complete; 1 hut built, fishing dock half-done, ambushed by two saber-toothed tigers"*), the LLM generates an in-character emergency report and tactical choices (e.g., *"Hold the half-built camp and wait for reinforcements"* vs. *"Abandon timber and retreat across the river"*).
   - Once resolved, the state machine resumes remaining blueprint steps, and the outcome is permanently archived in the leader's memory stream.

---

### 2.3 Individual Attributes & Proficiency Progression
Every unit has an individual character sheet and growth curve—no disposable "cannon fodder":
- **Core Stats**: Health (HP), Stamina/Hunger, Attack (ATK), Defense (DEF), Movement Speed (SPD).
- **Four Specialization Tracks (Lv. 0 – Lv. 10)**:
  1. **Foraging & Hunting**: +10% gathering/hunting speed and +5% lethal critical chance per level; unlocks **[Beast Taming]** at Lv. 5 to tame wild dinosaurs/megafauna.
  2. **Crafting & Building**: +12% construction speed and -5% material cost per level; unlocks **[Megalithic & Bronze Craft]** at Lv. 5 for monumental totems.
  3. **Combat & Leadership**: +15% ATK/DEF per level; unlocks **[Centurion Aura]** at Lv. 5, boosting morale and defense of nearby recruits.
  4. **Shamanism & Lore**: Accelerates tech research and ritual success rates; high-level shamans cast totem miracles (rainmaking, lightning strike, healing).

### 2.4 Streamlined "Tribal Wisdom Tree" (Tech Tree)
Focused exclusively on the dawn of civilization across three eras (9 core technologies):
1. **Stone & Fire Era**:
   - **Friction Fire**: Unlocks Bonfires, preventing nighttime hypothermia casualties and boosting food cooking efficiency.
   - **Polished Stone Tools**: Unlocks stone spears and axes (+30% hunting and woodcutting efficiency).
   - **Hide Tailoring**: Increases winter cold resistance and base armor.
2. **Tribe & Agrarian Era**:
   - **Primitive Pottery**: Unlocks Granaries (-50% food spoilage rate, higher population cap).
   - **Beast Domestication**: Allows taming Triceratops/aurochs for hauling or heavy cavalry charges.
   - **Slash-and-Burn Farming**: Unlocks primitive crop plots for steady plant-based food production.
3. **Bronze & Mythic Era**:
   - **Bronze Metallurgy**: Unlocks bronze heavy armor and spears, dramatically elevating military strength.
   - **Megalithic Totems**: Unlocks Grand Altars capable of summoning mythical guardian beasts (e.g., Yinglong, Behemoth).
   - **Tribal Code**: Increases Vice-Chieftain appointment slots by +1 and reduces unrest in large settlements.

### 2.5 Ancient Legends & Major Decision Events
Triggered dynamically by population thresholds, seasonal shifts, or tech breakthroughs:
- **[The Great Flood Warning]**: Shamans foresee torrential rains submerging low-lying camps.
  - *Option A (The Ark Plan)*: Spend heavy wood reserves to build highland rafts and shelters, saving all people and supplies.
  - *Option B (Sacrifice to the River Deity)*: Offer precious food and relics to appease the river god (success scales with Shaman level).
- **[Overpopulation Crisis]**: Tribe exceeds 20 members, depleting local game.
  - *Option A (Frontier Colonization)*: Appoint an experienced leader via a **Task Contract** to establish a sister settlement across the river.
  - *Option B (Territorial Conquest)*: Rally elite warriors to raid a neighboring rival tribe for land and resources.
- **[Birth of the Chosen One]**: At maximum tribal devotion, a hero bearing mythic bloodlines is born (archetypes inspired by Hou Yi the Archer, Yu the Flood-Tamer, or Chiyou the Berserker).

---

## 3. Technical Implementation & Distribution Roadmap

### 3.1 Technical Architecture & LLM Strategy
- **Game Engine**: **Godot 4** (preferred for lightweight node architecture matching Tribe–Unit–Contract hierarchies and rapid iteration) or **Unity** (for 3D Low-Poly aesthetics and mature NavMesh pathfinding).
- **Hybrid AI Architecture**:
  - **Micro Real-Time Layer (60 FPS)**: Deterministic behavior trees and state machines handling pathfinding, resource gathering, and melee combat with zero network latency.
  - **Macro Node Layer (Async LLM)**: Supports both **Local LLM** execution (e.g., Ollama running Qwen 2.5 / Llama 3 3B–7B models for zero-cost, offline play) as the primary initial integration target, and optional **Cloud API (BYOK)** endpoints (DeepSeek / GPT-4o-mini / Claude Haiku) with strict JSON Schema output enforcement.

### 3.2 Phased Distribution Strategy
1. **Phase 1 (Prototype Validation & Seed Community)**: Release an interactive Demo showcasing the Task Contract negotiation and individual progression loop on **Itch.io** and **Bilibili (DevLogs)** to gather feedback from core strategy/colony-sim players.
2. **Phase 2 (Steam Next Fest & Early Access)**: Participate in **Steam Next Fest** to build wishlists, followed by a **Steam Early Access** launch expanding Bronze Age content, mythic wonders, and cross-cultural legends.
3. **Phase 3 (Cross-Platform Expansion)**: Adapt UI for **iPad / Tablet** touch controls (point-and-assign + dialogue negotiation naturally fit tablet play) to reach premium mobile strategy audiences.

---

## 4. MVP Interactive Prototype Scope

To validate core gameplay fun, the MVP playable prototype implements:
1. **Real-Time Map & Entity Simulation**: Forests (wood), berry bushes/game (food), a river with a ford leading to an untamed eastern bank, tribal bonfires, and buildable huts/palisades.
2. **Node-Triggered Task Contract Negotiation & Interruption**:
   - Selecting different leaders (e.g., cautious builder *Panshi*, aggressive warrior *Alie*, mystic shaman *Linghe*) to colonize the east bank triggers a **Node Negotiation Modal** generating distinct personality-driven blueprints.
   - Execution runs autonomously via state machine with zero LLM overhead until a **mid-task ambush** triggers an **Emergency Awakening Modal** for player resolution.
3. **Individual XP Progression & Memory Archiving**: Units earn floating `+EXP` popups, level up stats/skills, and record completed contracts into their personal Memory Archives.
4. **Tribal Wisdom Tree & Mythic Events**: Unlockable technologies modifying real-time stats alongside scripted milestone events (Overpopulation & Great Flood).
