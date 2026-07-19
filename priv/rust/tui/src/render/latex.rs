//! Minimal LaTeX → Unicode transliteration for inline math.
//!
//! Models frequently emit inline math in `$…$` (and occasionally `$$…$$`) with
//! common TeX macros (`\alpha`, `\sum`, `\rightarrow`) and super/subscripts
//! (`x^2`, `H_2O`). A terminal cannot render real math, but a large fraction of
//! everyday math maps cleanly onto Unicode glyphs, which reads far better than the
//! raw TeX source. This module does *only* that safe subset:
//!
//!   * a curated table of named macros → their Unicode glyph,
//!   * `^`/`_` super- and sub-scripts for the characters that have Unicode
//!     super/subscript forms (digits, signs, parens, and the common letters).
//!
//! Anything it does not recognise is left byte-for-byte untouched, so unsupported
//! constructs (e.g. `\frac{a}{b}`) degrade to their literal source rather than
//! being mangled.
//!
//! Only [`render_math`] (used for the interior of a `$…$` span) is applied by the
//! markdown renderer — bare backslash runs in prose are deliberately **not**
//! converted, so Windows paths like `C:\alpha` and escaped text survive intact.

/// Convert the interior of a math span (`$…$`) to its best Unicode rendering:
/// named macros first, then super/subscripts. Unknown macros are preserved.
pub fn render_math(src: &str) -> String {
    let with_macros = replace_macros(src);
    apply_scripts(&with_macros)
}

/// Replace `\name` macros with their Unicode glyph. Unknown macros are left as
/// `\name` verbatim. A backslash followed by a non-letter (e.g. `\,`, `\\`) is
/// handled as a short spacing/escape macro where known, else passed through.
fn replace_macros(src: &str) -> String {
    let mut out = String::with_capacity(src.len());
    let mut chars = src.char_indices().peekable();

    while let Some((_, ch)) = chars.next() {
        if ch != '\\' {
            out.push(ch);
            continue;
        }
        // Read the macro name: a run of ASCII letters, else a single symbol
        // (TeX control symbol like `\,`).
        match chars.peek().copied() {
            Some((_, c)) if c.is_ascii_alphabetic() => {
                let mut name = String::new();
                while let Some(&(_, c)) = chars.peek() {
                    if c.is_ascii_alphabetic() {
                        name.push(c);
                        chars.next();
                    } else {
                        break;
                    }
                }
                match macro_glyph(&name) {
                    Some(g) => out.push_str(g),
                    None => {
                        // Unknown macro — preserve verbatim so nothing is lost.
                        out.push('\\');
                        out.push_str(&name);
                    }
                }
            }
            Some((_, c)) => {
                chars.next();
                match control_symbol(c) {
                    Some(g) => out.push_str(g),
                    None => {
                        out.push('\\');
                        out.push(c);
                    }
                }
            }
            None => out.push('\\'),
        }
    }
    out
}

/// Named-macro → Unicode glyph table (curated common subset).
fn macro_glyph(name: &str) -> Option<&'static str> {
    Some(match name {
        // ── lowercase Greek ──
        "alpha" => "α", "beta" => "β", "gamma" => "γ", "delta" => "δ",
        "epsilon" | "varepsilon" => "ε", "zeta" => "ζ", "eta" => "η",
        "theta" | "vartheta" => "θ", "iota" => "ι", "kappa" => "κ",
        "lambda" => "λ", "mu" => "μ", "nu" => "ν", "xi" => "ξ",
        "omicron" => "ο", "pi" => "π", "rho" | "varrho" => "ρ",
        "sigma" | "varsigma" => "σ", "tau" => "τ", "upsilon" => "υ",
        "phi" | "varphi" => "φ", "chi" => "χ", "psi" => "ψ", "omega" => "ω",
        // ── uppercase Greek ──
        "Gamma" => "Γ", "Delta" => "Δ", "Theta" => "Θ", "Lambda" => "Λ",
        "Xi" => "Ξ", "Pi" => "Π", "Sigma" => "Σ", "Upsilon" => "Υ",
        "Phi" => "Φ", "Psi" => "Ψ", "Omega" => "Ω",
        // ── binary operators / relations ──
        "sum" => "∑", "prod" => "∏", "coprod" => "∐", "int" => "∫",
        "iint" => "∬", "oint" => "∮", "pm" => "±", "mp" => "∓",
        "times" => "×", "div" => "÷", "cdot" => "·", "ast" => "∗",
        "star" => "⋆", "circ" => "∘", "bullet" => "•", "oplus" => "⊕",
        "otimes" => "⊗", "leq" | "le" => "≤", "geq" | "ge" => "≥",
        "neq" | "ne" => "≠", "approx" => "≈", "equiv" => "≡",
        "cong" => "≅", "sim" => "∼", "simeq" => "≃", "propto" => "∝",
        "ll" => "≪", "gg" => "≫", "subset" => "⊂", "supset" => "⊃",
        "subseteq" => "⊆", "supseteq" => "⊇", "cup" => "∪", "cap" => "∩",
        "setminus" => "∖", "perp" => "⊥", "parallel" => "∥", "angle" => "∠",
        // ── misc symbols ──
        "infty" => "∞", "partial" => "∂", "nabla" => "∇", "sqrt" => "√",
        "forall" => "∀", "exists" => "∃", "nexists" => "∄", "neg" | "lnot" => "¬",
        "in" => "∈", "notin" => "∉", "ni" => "∋", "emptyset" | "varnothing" => "∅",
        "wedge" | "land" => "∧", "vee" | "lor" => "∨", "oslash" => "⊘",
        "aleph" => "ℵ", "hbar" => "ℏ", "ell" => "ℓ", "Re" => "ℜ", "Im" => "ℑ",
        "wp" => "℘", "degree" | "deg" => "°", "prime" => "′", "dagger" => "†",
        "top" => "⊤", "bot" => "⊥", "vdots" => "⋮", "ddots" => "⋱",
        "checkmark" => "✓", "surd" => "√", "backslash" => "\\",
        // ── arrows ──
        "rightarrow" | "to" => "→", "gets" => "←",
        "leftarrow" => "←", "leftrightarrow" => "↔", "mapsto" => "↦",
        "Rightarrow" | "implies" => "⇒", "Leftarrow" | "impliedby" => "⇐",
        "Leftrightarrow" | "iff" => "⇔", "uparrow" => "↑", "downarrow" => "↓",
        "updownarrow" => "↕", "longrightarrow" => "⟶", "longleftarrow" => "⟵",
        "hookrightarrow" => "↪", "hookleftarrow" => "↩",
        // ── dots / ellipses ──
        "ldots" | "dots" => "…", "cdots" => "⋯",
        // ── named functions (kept as words) ──
        "sin" => "sin", "cos" => "cos", "tan" => "tan", "log" => "log",
        "ln" => "ln", "exp" => "exp", "lim" => "lim", "max" => "max",
        "min" => "min", "det" => "det", "gcd" => "gcd",
        // ── spacing macros collapse to a space (or nothing) ──
        "quad" | "qquad" | "," | ";" | ":" | "!" => " ",
        // ── delimiters that are noise in a terminal ──
        "left" | "right" | "big" | "Big" | "bigg" | "Bigg" | "mathrm"
        | "mathbf" | "mathit" | "text" | "textrm" | "displaystyle" => "",
        _ => return None,
    })
}

/// TeX control-symbol (`\` + single non-letter) glyphs.
fn control_symbol(c: char) -> Option<&'static str> {
    Some(match c {
        ',' | ';' | ':' | '!' | ' ' => " ", // thin/med/neg spaces → a space
        '\\' => "\n",                        // line break inside math
        '{' => "{",
        '}' => "}",
        '%' => "%",
        '$' => "$",
        '&' => "&",
        '#' => "#",
        '_' => "_",
        _ => return None,
    })
}

/// Apply `^`/`_` super- and subscripts. `^{ab}`/`_{ab}` groups and single-char
/// `^a`/`_a` are supported; a run that contains any non-mappable character is
/// left literal (with the braces stripped) so nothing is silently dropped.
fn apply_scripts(src: &str) -> String {
    let mut out = String::with_capacity(src.len());
    let mut chars = src.chars().peekable();

    while let Some(ch) = chars.next() {
        if ch != '^' && ch != '_' {
            out.push(ch);
            continue;
        }
        let sup = ch == '^';
        // Gather the script argument.
        let arg: String = match chars.peek() {
            Some('{') => {
                chars.next(); // consume `{`
                let mut g = String::new();
                for c in chars.by_ref() {
                    if c == '}' {
                        break;
                    }
                    g.push(c);
                }
                g
            }
            Some(_) => {
                // single character argument
                chars.next().map(|c| c.to_string()).unwrap_or_default()
            }
            None => {
                out.push(ch);
                continue;
            }
        };

        match map_script(&arg, sup) {
            Some(mapped) => out.push_str(&mapped),
            None => {
                // Not fully mappable — keep it readable as `^arg` / `_arg`.
                out.push(ch);
                out.push_str(&arg);
            }
        }
    }
    out
}

/// Map every char of `arg` to its super/subscript glyph, or `None` if any char
/// has no such form.
fn map_script(arg: &str, sup: bool) -> Option<String> {
    if arg.is_empty() {
        return None;
    }
    let mut out = String::with_capacity(arg.len());
    for c in arg.chars() {
        let g = if sup { superscript(c) } else { subscript(c) }?;
        out.push(g);
    }
    Some(out)
}

fn superscript(c: char) -> Option<char> {
    Some(match c {
        '0' => '⁰', '1' => '¹', '2' => '²', '3' => '³', '4' => '⁴',
        '5' => '⁵', '6' => '⁶', '7' => '⁷', '8' => '⁸', '9' => '⁹',
        '+' => '⁺', '-' => '⁻', '=' => '⁼', '(' => '⁽', ')' => '⁾',
        'a' => 'ᵃ', 'b' => 'ᵇ', 'c' => 'ᶜ', 'd' => 'ᵈ', 'e' => 'ᵉ',
        'f' => 'ᶠ', 'g' => 'ᵍ', 'h' => 'ʰ', 'i' => 'ⁱ', 'j' => 'ʲ',
        'k' => 'ᵏ', 'l' => 'ˡ', 'm' => 'ᵐ', 'n' => 'ⁿ', 'o' => 'ᵒ',
        'p' => 'ᵖ', 'r' => 'ʳ', 's' => 'ˢ', 't' => 'ᵗ', 'u' => 'ᵘ',
        'v' => 'ᵛ', 'w' => 'ʷ', 'x' => 'ˣ', 'y' => 'ʸ', 'z' => 'ᶻ',
        'A' => 'ᴬ', 'B' => 'ᴮ', 'D' => 'ᴰ', 'E' => 'ᴱ', 'G' => 'ᴳ',
        'H' => 'ᴴ', 'I' => 'ᴵ', 'J' => 'ᴶ', 'K' => 'ᴷ', 'L' => 'ᴸ',
        'M' => 'ᴹ', 'N' => 'ᴺ', 'O' => 'ᴼ', 'P' => 'ᴾ', 'R' => 'ᴿ',
        'T' => 'ᵀ', 'U' => 'ᵁ', 'V' => 'ⱽ', 'W' => 'ᵂ',
        '.' => '·', ' ' => ' ',
        _ => return None,
    })
}

fn subscript(c: char) -> Option<char> {
    Some(match c {
        '0' => '₀', '1' => '₁', '2' => '₂', '3' => '₃', '4' => '₄',
        '5' => '₅', '6' => '₆', '7' => '₇', '8' => '₈', '9' => '₉',
        '+' => '₊', '-' => '₋', '=' => '₌', '(' => '₍', ')' => '₎',
        'a' => 'ₐ', 'e' => 'ₑ', 'h' => 'ₕ', 'i' => 'ᵢ', 'j' => 'ⱼ',
        'k' => 'ₖ', 'l' => 'ₗ', 'm' => 'ₘ', 'n' => 'ₙ', 'o' => 'ₒ',
        'p' => 'ₚ', 'r' => 'ᵣ', 's' => 'ₛ', 't' => 'ₜ', 'u' => 'ᵤ',
        'v' => 'ᵥ', 'x' => 'ₓ', ' ' => ' ',
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn greek_and_operators() {
        assert_eq!(render_math("\\alpha + \\beta"), "α + β");
        assert_eq!(render_math("\\sum x"), "∑ x");
        assert_eq!(render_math("a \\rightarrow b"), "a → b");
        assert_eq!(render_math("\\Omega \\neq \\emptyset"), "Ω ≠ ∅");
    }

    #[test]
    fn superscripts_and_subscripts() {
        assert_eq!(render_math("x^2"), "x²");
        assert_eq!(render_math("H_2O"), "H₂O");
        assert_eq!(render_math("a^{10}"), "a¹⁰");
        assert_eq!(render_math("x_i^2"), "xᵢ²");
        assert_eq!(render_math("e^{-x}"), "e⁻ˣ");
    }

    #[test]
    fn combined_macro_and_script() {
        assert_eq!(render_math("\\sigma^2"), "σ²");
        assert_eq!(render_math("\\sum_{i=1}^{n} i"), "∑ᵢ₌₁ⁿ i");
    }

    #[test]
    fn unknown_macro_is_preserved() {
        assert_eq!(render_math("\\frac{a}{b}"), "\\frac{a}{b}");
        // Unmappable superscript run stays literal (braces stripped).
        assert_eq!(render_math("x^{@#}"), "x^@#");
    }

    #[test]
    fn plain_text_unchanged() {
        assert_eq!(render_math("just words"), "just words");
        assert_eq!(render_math("5 dollars"), "5 dollars");
    }
}
