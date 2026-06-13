#include "teams.h"
#include <string.h>
#include "flags.h"

namespace {
struct HandPicked {
  const char* code;
  const char* name;
  Rgb color;
};

// Tier 1 — hand-picked, from Matrix.Teams @hand_picked (wc-data.js c1 hex).
const HandPicked HAND[] = {
    {"USA", "USA", {0x5B, 0x8C, 0xFF}},
    {"MEX", "MEXICO", {0x34, 0xC8, 0x78}},
    {"CAN", "CANADA", {0xFF, 0x5C, 0x5C}},
    {"BRA", "BRAZIL", {0xFF, 0xD2, 0x3F}},
    {"ARG", "ARGENTINA", {0x6C, 0xC4, 0xF5}},
    {"FRA", "FRANCE", {0x5B, 0x8C, 0xFF}},
    {"ENG", "ENGLAND", {0xD7, 0xE2, 0xFB}},
    {"ESP", "SPAIN", {0xFF, 0x5C, 0x5C}},
    {"GER", "GERMANY", {0xFF, 0xCE, 0x5C}},
    {"POR", "PORTUGAL", {0xFF, 0x6F, 0x6F}},
    {"NED", "NETHERLANDS", {0xFF, 0x9D, 0x3C}},
    {"BEL", "BELGIUM", {0xFF, 0xCE, 0x5C}},
    {"CRO", "CROATIA", {0xFF, 0x5C, 0x5C}},
    {"URU", "URUGUAY", {0x6C, 0xC4, 0xF5}},
    {"COL", "COLOMBIA", {0xFF, 0xD2, 0x3F}},
    {"JPN", "JAPAN", {0x5B, 0x8C, 0xFF}},
    {"KOR", "KOREA", {0xFF, 0x5C, 0x5C}},
    {"SEN", "SENEGAL", {0x34, 0xC8, 0x78}},
    {"MAR", "MOROCCO", {0xFF, 0x5C, 0x5C}},
    {"AUS", "AUSTRALIA", {0xFF, 0xD2, 0x3F}},
    {"SUI", "SWITZERLAND", {0xFF, 0x5C, 0x5C}},
};
const int HAND_COUNT = sizeof(HAND) / sizeof(HAND[0]);

// Tier 2 — derived names, from Matrix.Teams @derived_names. Colors come from
// the flag accent (Flags::accent), exactly as the Elixir @derived does.
struct Derived {
  const char* code;
  const char* name;
};
const Derived DERIVED[] = {
    {"ALG", "ALGERIA"},     {"AUT", "AUSTRIA"},  {"BIH", "BOSNIA-HERZEGOVINA"},
    {"CIV", "IVORY COAST"}, {"COD", "DR CONGO"}, {"CPV", "CABO VERDE"},
    {"CUW", "CURACAO"},     {"CZE", "CZECHIA"},  {"ECU", "ECUADOR"},
    {"EGY", "EGYPT"},       {"GHA", "GHANA"},    {"HAI", "HAITI"},
    {"IRN", "IRAN"},        {"IRQ", "IRAQ"},     {"JOR", "JORDAN"},
    {"KSA", "SAUDI ARABIA"},{"NOR", "NORWAY"},   {"NZL", "NEW ZEALAND"},
    {"PAN", "PANAMA"},      {"PAR", "PARAGUAY"}, {"QAT", "QATAR"},
    {"RSA", "SOUTH AFRICA"},{"SCO", "SCOTLAND"}, {"SWE", "SWEDEN"},
    {"TUN", "TUNISIA"},     {"TUR", "TURKIYE"},  {"UZB", "UZBEKISTAN"},
};
const int DERIVED_COUNT = sizeof(DERIVED) / sizeof(DERIVED[0]);

// teamC1's fallback in wc-data.js: '#e4ecff'.
const Rgb FALLBACK = {0xE4, 0xEC, 0xFF};

const HandPicked* findHand(const char* code) {
  for (int i = 0; i < HAND_COUNT; i++)
    if (strcmp(HAND[i].code, code) == 0) return &HAND[i];
  return nullptr;
}
const Derived* findDerived(const char* code) {
  for (int i = 0; i < DERIVED_COUNT; i++)
    if (strcmp(DERIVED[i].code, code) == 0) return &DERIVED[i];
  return nullptr;
}
}  // namespace

namespace Teams {

const char* name(const char* code) {
  if (const HandPicked* h = findHand(code)) return h->name;
  if (const Derived* d = findDerived(code)) return d->name;
  return code;  // unknown codes echo the code
}

Rgb color(const char* code) {
  // Hand-picked entries win on any overlap (design-authoritative).
  if (const HandPicked* h = findHand(code)) return h->color;
  Rgb a;
  if (Flags::accent(code, a)) return a;  // derived → flag accent
  return FALLBACK;
}

}  // namespace Teams
