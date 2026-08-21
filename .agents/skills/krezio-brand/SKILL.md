---
name: krezio-brand
description: >-
  Brand guidelines, UX writing guidelines, Flutter color palettes, typography, and design system specifications for Krezio.ai.
  Use whenever generating Flutter code, UI components, screens, copy, UX writing, or marketing copy for Krezio.ai.
---

# Krezio.ai Brand Guidelines & Design System

This skill defines the visual identity, UX writing principles, and Flutter design system tokens for the **Krezio.ai** application.

---

## 1. Brand Identity
- **Name:** Krezio.ai
- **Niche:** Personal Financial Management & Virtual Assistant App.
- **Promise:** *"O futuro das suas finanças, guiado por dados."*
- **Personality:** Intelligent, secure, modern, and encouraging. Money is a sensitive topic; Krezio.ai is **never punitive or alarmist**. It guides, predicts, and helps the user grow.

---

## 2. Tone of Voice (UX Writing)
- **Empathetic & Direct:** Clear communication focused on helpful insights.
- **No Boring Jargon:** Replace complex banking or technical terms with user-friendly language.
  - *Example:* Instead of *"Déficit Orçamentário"*, use *"Seus gastos ultrapassaram a meta"*.
- **Data-Driven Advisor (".ai"):** Use natural advisor phrasing, e.g.:
  - *"Notei que..."*
  - *"A previsão para este mês é..."*
  - *"Que tal ajustar..."*

---

## 3. Design System Specs (Flutter)
- **Typography:** `Space Grotesk` or `Plus Jakarta Sans`.
- **Border Radius:** Friendly rounded corners (`BorderRadius.circular(16)`).
- **Theme Support:** Mandatory support for both **Light Mode** and **Dark Mode**.
- **Layout Style:** Minimalist, clean design focused on **Dashboard / Insights**.

---

## 4. Color Palette Specifications

### Brand & Status Colors
- **Primary Color (Intelligence / Action):** AI Purple `#8B5CF6` (`Color(0xFF8B5CF6)`)
- **Success / Income (Growth):** Emerald Green `#10B981` (`Color(0xFF10B981)`)
- **Alert / Expense (Friendly Attention):** Friendly Orange `#F97316` (`Color(0xFFF97316)`)
  - ⚠️ **CRITICAL RULE:** **NEVER** use blood red (`#FF0000`, `#E53935`, etc.) for expenses or alerts, avoiding anxiety triggers. Always use Friendly Orange (`#F97316`).

### Background & Surface Tokens

#### Light Mode
- **Background:** `#F9FAFB` (`Color(0xFFF9FAFB)`)
- **Surface / Cards:** `#FFFFFF` (`Color(0xFFFFFFFF)`)
- **Primary Text:** `#111827` (`Color(0xFF111827)`)
- **Secondary Text:** `#6B7280` (`Color(0xFF6B7280)`)
- **Shadows:** Light, subtle drop shadows.

#### Dark Mode
- **Background:** `#121212` (`Color(0xFF121212)`)
- **Surface / Cards:** `#1E1E1E` or `#27272A` (`Color(0xFF1E1E1E)` / `Color(0xFF27272A)`)
- **Primary Text:** `#F3F4F6` (`Color(0xFFF3F4F6)`)
- **Secondary Text:** `#9CA3AF` (`Color(0xFF9CA3AF)`)
- **Shadows:** No external shadows; rely strictly on surface color contrast.

---

## 5. Execution Guidelines
Whenever requested to generate Flutter screens, components, layout specs, or text content:
1. Always implement these exact color variables, typography rules, and `BorderRadius.circular(16)`.
2. Ensure both Light and Dark theme configurations match these exact hex codes.
3. Keep UI layouts minimalist with an emphasis on insights cards and dashboards.
4. Apply the empathetic, data-backed advisor tone in all UX copy.
