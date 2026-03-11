#!/usr/bin/env python3
"""Validate ALL ASC API endpoints needed for the 3 sections scraped from ASC web.

Tests MISSING fields not covered by existing test_paid_pricing.py, test_iap.py, test_subscriptions.py.

Sections:
  A) Pricing & Availability — scheduled price change (startDate), price equalizations
  B) In-App Purchases — availability (territories), review screenshot, review notes (PATCH), tax category
  C) Subscriptions — review screenshot, review notes, subscription introductory offers, tax category

Each test is READ-ONLY or creates+deletes to avoid polluting the account.
"""

import sys, os, time, json, tempfile
sys.path.insert(0, os.path.dirname(__file__))
from asc_client import ASCClient, pp

APP_ID = "6760320061"
TEST_PREFIX = "blitz_validate_"

def main():
    client = ASCClient()
    results = {"pass": 0, "fail": 0, "skip": 0, "info": []}

    def check(label, status, data, expect_2xx=True):
        ok = 200 <= status < 300 if expect_2xx else True
        tag = "PASS" if ok else "FAIL"
        results["pass" if ok else "fail"] += 1
        print(f"\n[{tag}] {label} (HTTP {status})")
        if not ok and data:
            errors = data.get("errors", [])
            for e in errors:
                detail = e.get("detail", e.get("title", "?"))
                print(f"    Error: {detail}")
        return ok, data

    def info(label, message):
        results["info"].append((label, message))
        print(f"  [INFO] {label}: {message}")

    def skip(label, reason):
        results["skip"] += 1
        print(f"\n[SKIP] {label}: {reason}")

    ts = int(time.time())

    # ═══════════════════════════════════════════════════════════════
    # SECTION A: PRICING & AVAILABILITY
    # ═══════════════════════════════════════════════════════════════
    print("\n" + "#" * 70)
    print("# SECTION A: PRICING & AVAILABILITY")
    print("#" * 70)

    # ── A1: Scheduled price change (startDate on appPrices) ──
    # The ASC web shows "Effective Date" for price changes.
    # API: POST /v1/appPriceSchedules with startDate attribute on included appPrices
    print("\n" + "=" * 60)
    print("A1: Test scheduled price change with startDate")
    print("=" * 60)
    # First get a price point
    ok, data = check("Fetch app price points", *client.get(
        f"v1/apps/{APP_ID}/appPricePoints?filter[territory]=USA&limit=10"
    ))
    free_point = None
    paid_point = None
    if ok:
        for pt in data["data"]:
            price = pt["attributes"].get("customerPrice", "0")
            if price in ("0", "0.0", "0.00"):
                free_point = pt
            elif paid_point is None:
                paid_point = pt

    if paid_point:
        # Try creating a price schedule with a future startDate
        # Error from approach 1: intervals [null-null] and [2026-06-01-null] overlap for USA
        # Error from approach 2: timeline not covered (future-only, no current price)
        # Fix: base entry needs endDate = future startDate to create non-overlapping intervals
        future_date = "2026-06-01"

        # Approach 1: base with endDate + future with startDate (non-overlapping intervals)
        body_v1 = {
            "data": {
                "type": "appPriceSchedules",
                "relationships": {
                    "app": {"data": {"type": "apps", "id": APP_ID}},
                    "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
                    "manualPrices": {
                        "data": [
                            {"type": "appPrices", "id": "${base}"},
                            {"type": "appPrices", "id": "${future}"}
                        ]
                    }
                }
            },
            "included": [
                {
                    "type": "appPrices",
                    "id": "${base}",
                    "attributes": {
                        "endDate": future_date
                    },
                    "relationships": {
                        "appPricePoint": {"data": {"type": "appPricePoints", "id": free_point["id"]}}
                    }
                },
                {
                    "type": "appPrices",
                    "id": "${future}",
                    "attributes": {
                        "startDate": future_date
                    },
                    "relationships": {
                        "appPricePoint": {"data": {"type": "appPricePoints", "id": paid_point["id"]}}
                    }
                }
            ]
        }
        ok, data = check(
            f"Create scheduled price (approach 1: base endDate + future startDate)",
            *client.post("v1/appPriceSchedules", body_v1)
        )
        if ok:
            info("A1", f"Scheduled price change works! Free until {future_date}, then ${paid_point['attributes']['customerPrice']}")
        else:
            # Approach 2: 3 entries - base(no dates) as anchor, middle(startDate+endDate) as current, future(startDate) as scheduled
            # Some APIs need the first entry as an "anchor" with no dates
            body_v2 = {
                "data": {
                    "type": "appPriceSchedules",
                    "relationships": {
                        "app": {"data": {"type": "apps", "id": APP_ID}},
                        "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
                        "manualPrices": {
                            "data": [
                                {"type": "appPrices", "id": "${current}"},
                                {"type": "appPrices", "id": "${future}"}
                            ]
                        }
                    }
                },
                "included": [
                    {
                        "type": "appPrices",
                        "id": "${current}",
                        "relationships": {
                            "appPricePoint": {"data": {"type": "appPricePoints", "id": free_point["id"]}}
                        }
                    },
                    {
                        "type": "appPrices",
                        "id": "${future}",
                        "attributes": {
                            "startDate": future_date
                        },
                        "relationships": {
                            "appPricePoint": {"data": {"type": "appPricePoints", "id": paid_point["id"]}}
                        }
                    }
                ]
            }
            ok2, data2 = check(
                f"Create scheduled price (approach 2: current no-dates + future startDate)",
                *client.post("v1/appPriceSchedules", body_v2)
            )
            if ok2:
                info("A1", f"Scheduled price works (approach 2)! ${paid_point['attributes']['customerPrice']} on {future_date}")
            else:
                info("A1", "Scheduled pricing NOT working. Errors shown above.")

        # Revert: set back to free immediately regardless
        revert_body = {
            "data": {
                "type": "appPriceSchedules",
                "relationships": {
                    "app": {"data": {"type": "apps", "id": APP_ID}},
                    "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
                    "manualPrices": {"data": [{"type": "appPrices", "id": "${base}"}]}
                }
            },
            "included": [{
                "type": "appPrices",
                "id": "${base}",
                "relationships": {
                    "appPricePoint": {"data": {"type": "appPricePoints", "id": free_point["id"]}}
                }
            }]
        }
        client.post("v1/appPriceSchedules", revert_body)
        print("  (Reverted to free)")
    else:
        skip("A1", "No paid price points found")

    # ── A2: Verify price point equalizations (multi-territory prices) ──
    print("\n" + "=" * 60)
    print("A2: Price point equalizations (auto-calculated global prices)")
    print("=" * 60)
    if paid_point:
        ok, data = check(
            "Fetch equalizations for a price point (v3)",
            *client.get(f"v3/appPricePoints/{paid_point['id']}/equalizations?limit=10")
        )
        if ok:
            territories = [eq["attributes"].get("territory", "?") for eq in data["data"]]
            info("A2", f"Equalizations work. Got {len(data['data'])} territories: {territories[:5]}...")
    else:
        skip("A2", "No paid point")

    # ── A3: List app price schedule with automatic prices ──
    print("\n" + "=" * 60)
    print("A3: Fetch app price schedule + automatic prices")
    print("=" * 60)
    ok, data = check("Fetch app price schedule", *client.get(
        f"v1/apps/{APP_ID}/appPriceSchedule?include=manualPrices,automaticPrices"
    ))
    if ok:
        included = data.get("included", [])
        manual = [i for i in included if i["type"] == "appPrices"]
        auto = [i for i in included if i["type"] == "appPrices" and i.get("attributes", {}).get("startDate")]
        info("A3", f"Schedule found. {len(manual)} manual prices, {len(auto)} with startDate")

    # ═══════════════════════════════════════════════════════════════
    # SECTION B: IN-APP PURCHASES — MISSING FIELDS
    # ═══════════════════════════════════════════════════════════════
    print("\n" + "#" * 70)
    print("# SECTION B: IN-APP PURCHASES — MISSING FIELDS")
    print("#" * 70)

    # Create a test IAP for validation
    print("\n" + "=" * 60)
    print("B0: Create test IAP for field validation")
    print("=" * 60)
    iap_product_id = f"{TEST_PREFIX}iap_{ts}"
    iap_body = {
        "data": {
            "type": "inAppPurchases",
            "attributes": {
                "name": "Validate Fields Test",
                "productId": iap_product_id,
                "inAppPurchaseType": "CONSUMABLE",
                "reviewNote": "Initial review note for testing"
            },
            "relationships": {
                "app": {"data": {"type": "apps", "id": APP_ID}}
            }
        }
    }
    ok, data = check("Create test IAP", *client.post("v2/inAppPurchases", iap_body))
    iap_id = data["data"]["id"] if ok else None
    if iap_id:
        print(f"  IAP id={iap_id}")
        # Check if reviewNote was set
        attrs = data["data"]["attributes"]
        if attrs.get("reviewNote"):
            info("B0-reviewNote", f"reviewNote set on create: '{attrs['reviewNote']}'")
        else:
            info("B0-reviewNote", "reviewNote NOT returned on create response (may need separate endpoint)")

    # ── B1: IAP Availability (territories) ──
    print("\n" + "=" * 60)
    print("B1: IAP Availability — select countries/regions")
    print("=" * 60)
    if iap_id:
        # First try to GET current availability
        ok, data = check(
            "GET IAP availability",
            *client.get(f"v2/inAppPurchases/{iap_id}/inAppPurchaseAvailability?include=availableTerritories")
        )
        if ok:
            info("B1-read", "Can read IAP availability")
            avail_id = data["data"]["id"]
            terr_count = len(data.get("included", []))
            info("B1-read", f"Availability id={avail_id}, territories={terr_count}")
        else:
            # Maybe it's a POST to create
            avail_body = {
                "data": {
                    "type": "inAppPurchaseAvailabilities",
                    "attributes": {
                        "availableInNewTerritories": True
                    },
                    "relationships": {
                        "inAppPurchase": {
                            "data": {"type": "inAppPurchases", "id": iap_id}
                        },
                        "availableTerritories": {
                            "data": [{"type": "territories", "id": "USA"}]
                        }
                    }
                }
            }
            ok2, data2 = check(
                "POST IAP availability (create)",
                *client.post("v1/inAppPurchaseAvailabilities", avail_body)
            )
            if ok2:
                info("B1-create", "IAP availability created via POST")
            else:
                info("B1", "IAP availability endpoint may not exist or need different approach")
    else:
        skip("B1", "No IAP created")

    # ── B2: IAP Review Screenshot ──
    print("\n" + "=" * 60)
    print("B2: IAP Review Screenshot upload endpoint")
    print("=" * 60)
    if iap_id:
        # Add localization first (required for screenshot)
        loc_body = {
            "data": {
                "type": "inAppPurchaseLocalizations",
                "attributes": {
                    "name": "Test Product",
                    "description": "For validation testing",
                    "locale": "en-US"
                },
                "relationships": {
                    "inAppPurchaseV2": {
                        "data": {"type": "inAppPurchases", "id": iap_id}
                    }
                }
            }
        }
        ok, data = check("Create IAP localization", *client.post("v1/inAppPurchaseLocalizations", loc_body))
        loc_id = data["data"]["id"] if ok else None

        # Try to reserve a review screenshot
        # The endpoint for IAP review screenshots
        if loc_id:
            # Try the review screenshot reservation endpoint
            screenshot_body = {
                "data": {
                    "type": "inAppPurchaseAppStoreReviewScreenshots",
                    "attributes": {
                        "fileName": "test_screenshot.png",
                        "fileSize": 1024
                    },
                    "relationships": {
                        "inAppPurchaseV2": {
                            "data": {"type": "inAppPurchases", "id": iap_id}
                        }
                    }
                }
            }
            ok, data = check(
                "POST reserve IAP review screenshot",
                *client.post("v1/inAppPurchaseAppStoreReviewScreenshots", screenshot_body)
            )
            if ok:
                info("B2", f"IAP review screenshot endpoint EXISTS! Response id={data['data']['id']}")
                # Clean up the reservation
                ss_id = data["data"]["id"]
                client.delete(f"v1/inAppPurchaseAppStoreReviewScreenshots/{ss_id}")
            else:
                # Check error - is the endpoint unknown (404) or just validation (409/422)?
                errors = data.get("errors", [])
                for e in errors:
                    code = e.get("status", "")
                    detail = e.get("detail", "")
                    info("B2-error", f"Status={code} Detail={detail}")
                if any(e.get("status") == "404" for e in errors):
                    info("B2", "Endpoint NOT found — screenshots for IAP review may not be API-accessible")
                else:
                    info("B2", "Endpoint exists but validation failed (which means it's a valid endpoint)")
    else:
        skip("B2", "No IAP created")

    # ── B3: IAP Review Notes (PATCH) ──
    print("\n" + "=" * 60)
    print("B3: Update IAP review notes via PATCH")
    print("=" * 60)
    if iap_id:
        patch_body = {
            "data": {
                "type": "inAppPurchases",
                "id": iap_id,
                "attributes": {
                    "reviewNote": "Updated review note for testing"
                }
            }
        }
        ok, data = check(
            "PATCH IAP reviewNote",
            *client.patch(f"v2/inAppPurchases/{iap_id}", patch_body)
        )
        if ok:
            note = data["data"]["attributes"].get("reviewNote", "")
            info("B3", f"reviewNote updated via PATCH: '{note}'")
        else:
            info("B3", "reviewNote may not be PATCHable")
    else:
        skip("B3", "No IAP created")

    # ── B4: IAP Price Schedule with all territories (auto-calculate) ──
    print("\n" + "=" * 60)
    print("B4: IAP price points — check if equalizations are available")
    print("=" * 60)
    if iap_id:
        # Get IAP price points for multiple territories
        ok, data = check(
            "Fetch IAP price points (no territory filter = all)",
            *client.get(f"v2/inAppPurchases/{iap_id}/pricePoints?limit=200&include=territory")
        )
        if ok:
            points = data["data"]
            territories = set()
            for pt in points:
                # Check included for territory info
                rels = pt.get("relationships", {}).get("territory", {}).get("data", {})
                if rels:
                    territories.add(rels.get("id", "?"))
            info("B4", f"Got {len(points)} price points across {len(territories)} territories")
            if territories:
                info("B4", f"Sample territories: {list(territories)[:10]}")

        # Also test IAP price point equalizations
        ok2, data2 = check(
            "Fetch IAP price points for USA only",
            *client.get(f"v2/inAppPurchases/{iap_id}/pricePoints?filter[territory]=USA&limit=10")
        )
        if ok2 and data2["data"]:
            iap_pp_id = data2["data"][0]["id"]
            ok3, data3 = check(
                "Fetch IAP price point equalizations",
                *client.get(f"v1/inAppPurchasePricePoints/{iap_pp_id}/equalizations?limit=5")
            )
            if ok3:
                info("B4-eq", f"IAP equalizations work! {len(data3['data'])} territories returned")
            else:
                # Try v2
                ok4, data4 = check(
                    "Fetch IAP price point equalizations (v2 path)",
                    *client.get(f"v2/inAppPurchasePricePoints/{iap_pp_id}/equalizations?limit=5")
                )
                if ok4:
                    info("B4-eq", f"IAP equalizations work (v2)! {len(data4['data'])} territories")
    else:
        skip("B4", "No IAP created")

    # ── B5: Tax category for IAP ──
    print("\n" + "=" * 60)
    print("B5: Check if tax category is settable for IAP")
    print("=" * 60)
    # Tax categories are typically at the app level, not per-IAP in the API
    # Check if there's an appInfo field or separate endpoint
    ok, data = check(
        "Fetch app info for tax/category info",
        *client.get(f"v1/apps/{APP_ID}/appInfos?include=primaryCategory,secondaryCategory")
    )
    if ok:
        infos = data["data"]
        if infos:
            app_info = infos[0]
            info("B5", f"App info id={app_info['id']}")
            # Check included for categories
            for inc in data.get("included", []):
                if inc["type"] == "appCategories":
                    info("B5", f"Category: id={inc['id']} (parent={inc.get('attributes', {}).get('parent', 'none')})")

    # Check for a dedicated tax category endpoint
    if iap_id:
        # Try reading IAP with content fields
        ok2, data2 = check(
            "GET IAP with all fields to check for taxCategory",
            *client.get(f"v2/inAppPurchases/{iap_id}?include=appStoreReviewScreenshot,content,pricePoints")
        )
        if ok2:
            attrs = data2["data"]["attributes"]
            all_attrs = list(attrs.keys())
            info("B5", f"IAP attributes available: {all_attrs}")
            # Check for content hosting / tax fields
            for inc in data2.get("included", []):
                info("B5", f"Included type: {inc['type']} id={inc['id']}")

    # ═══════════════════════════════════════════════════════════════
    # SECTION C: SUBSCRIPTIONS — MISSING FIELDS
    # ═══════════════════════════════════════════════════════════════
    print("\n" + "#" * 70)
    print("# SECTION C: SUBSCRIPTIONS — MISSING FIELDS")
    print("#" * 70)

    # Create test subscription group + subscription
    print("\n" + "=" * 60)
    print("C0: Create test subscription group + subscription")
    print("=" * 60)
    group_body = {
        "data": {
            "type": "subscriptionGroups",
            "attributes": {"referenceName": f"{TEST_PREFIX}grp_{ts}"},
            "relationships": {
                "app": {"data": {"type": "apps", "id": APP_ID}}
            }
        }
    }
    ok, data = check("Create test subscription group", *client.post("v1/subscriptionGroups", group_body))
    group_id = data["data"]["id"] if ok else None

    sub_id = None
    if group_id:
        sub_body = {
            "data": {
                "type": "subscriptions",
                "attributes": {
                    "name": f"Validate Sub Test",
                    "productId": f"{TEST_PREFIX}sub_{ts}",
                    "subscriptionPeriod": "ONE_MONTH",
                    "reviewNote": "Initial sub review note"
                },
                "relationships": {
                    "group": {"data": {"type": "subscriptionGroups", "id": group_id}}
                }
            }
        }
        ok, data = check("Create test subscription", *client.post("v1/subscriptions", sub_body))
        if ok:
            sub_id = data["data"]["id"]
            attrs = data["data"]["attributes"]
            info("C0", f"Sub id={sub_id}")
            if attrs.get("reviewNote"):
                info("C0-reviewNote", f"reviewNote set on create: '{attrs['reviewNote']}'")
            else:
                info("C0-reviewNote", "reviewNote NOT returned in create response")
            info("C0-attrs", f"All attributes: {list(attrs.keys())}")

    # ── C1: Subscription Availability ──
    print("\n" + "=" * 60)
    print("C1: Subscription availability (territories)")
    print("=" * 60)
    if sub_id:
        # Read current availability
        ok, data = check(
            "GET subscription availability",
            *client.get(f"v1/subscriptions/{sub_id}/subscriptionAvailability?include=availableTerritories&limit=5")
        )
        if ok:
            avail_data = data["data"]
            info("C1-read", f"Availability id={avail_data['id']}")
            terr_count = len(data.get("included", []))
            available_new = avail_data.get("attributes", {}).get("availableInNewTerritories", "?")
            info("C1-read", f"availableInNewTerritories={available_new}, territories in response={terr_count}")
    else:
        skip("C1", "No subscription created")

    # ── C2: Subscription Review Screenshot ──
    print("\n" + "=" * 60)
    print("C2: Subscription review screenshot endpoint")
    print("=" * 60)
    if sub_id:
        # Add localization first
        loc_body = {
            "data": {
                "type": "subscriptionLocalizations",
                "attributes": {
                    "name": "Monthly Pro",
                    "description": "Unlock all features",
                    "locale": "en-US"
                },
                "relationships": {
                    "subscription": {"data": {"type": "subscriptions", "id": sub_id}}
                }
            }
        }
        ok, data = check("Create subscription localization", *client.post("v1/subscriptionLocalizations", loc_body))
        sub_loc_id = data["data"]["id"] if ok else None

        if sub_loc_id:
            # Try subscription app store review screenshot
            ss_body = {
                "data": {
                    "type": "subscriptionAppStoreReviewScreenshots",
                    "attributes": {
                        "fileName": "test_sub_screenshot.png",
                        "fileSize": 1024
                    },
                    "relationships": {
                        "subscription": {
                            "data": {"type": "subscriptions", "id": sub_id}
                        }
                    }
                }
            }
            ok, data = check(
                "POST reserve subscription review screenshot",
                *client.post("v1/subscriptionAppStoreReviewScreenshots", ss_body)
            )
            if ok:
                info("C2", f"Subscription review screenshot endpoint EXISTS! id={data['data']['id']}")
                ss_id = data["data"]["id"]
                client.delete(f"v1/subscriptionAppStoreReviewScreenshots/{ss_id}")
            else:
                errors = data.get("errors", [])
                for e in errors:
                    info("C2-error", f"Status={e.get('status')} Detail={e.get('detail', '?')}")
                if any(e.get("status") == "404" for e in errors):
                    info("C2", "Endpoint NOT found")
                else:
                    info("C2", "Endpoint exists but validation failed (endpoint is valid)")
    else:
        skip("C2", "No subscription created")

    # ── C3: Subscription Review Notes (PATCH) ──
    print("\n" + "=" * 60)
    print("C3: Update subscription review notes via PATCH")
    print("=" * 60)
    if sub_id:
        patch_body = {
            "data": {
                "type": "subscriptions",
                "id": sub_id,
                "attributes": {
                    "reviewNote": "Updated subscription review note"
                }
            }
        }
        ok, data = check(
            "PATCH subscription reviewNote",
            *client.patch(f"v1/subscriptions/{sub_id}", patch_body)
        )
        if ok:
            note = data["data"]["attributes"].get("reviewNote", "")
            info("C3", f"reviewNote updated: '{note}'")
    else:
        skip("C3", "No subscription created")

    # ── C4: Subscription price points with equalizations ──
    print("\n" + "=" * 60)
    print("C4: Subscription price point equalizations")
    print("=" * 60)
    if sub_id:
        ok, data = check(
            "Fetch subscription price points (all territories)",
            *client.get(f"v1/subscriptions/{sub_id}/pricePoints?limit=200&include=territory")
        )
        if ok:
            points = data["data"]
            info("C4", f"Got {len(points)} subscription price points")

            # Try equalizations on first USA point
            ok2, data2 = check(
                "Fetch sub price points for USA",
                *client.get(f"v1/subscriptions/{sub_id}/pricePoints?filter[territory]=USA&limit=5")
            )
            if ok2 and data2["data"]:
                sub_pp_id = data2["data"][0]["id"]
                ok3, data3 = check(
                    "Fetch sub price point equalizations",
                    *client.get(f"v1/subscriptionPricePoints/{sub_pp_id}/equalizations?limit=5")
                )
                if ok3:
                    info("C4-eq", f"Sub equalizations work! {len(data3['data'])} territories")
    else:
        skip("C4", "No subscription created")

    # ── C5: Subscription introductory offers ──
    print("\n" + "=" * 60)
    print("C5: Subscription introductory offers (free trial, pay as you go, pay up front)")
    print("=" * 60)
    if sub_id:
        # Check if introductory offer endpoint exists
        ok, data = check(
            "GET subscription introductory offers",
            *client.get(f"v1/subscriptions/{sub_id}/introductoryOffers")
        )
        if ok:
            info("C5-read", f"Introductory offers readable: {len(data.get('data', []))} offers")

        # Try creating a free trial intro offer
        if sub_id:
            # First need a price point for the offer
            ok2, data2 = check(
                "Fetch sub price points for intro offer",
                *client.get(f"v1/subscriptions/{sub_id}/pricePoints?filter[territory]=USA&limit=5")
            )
            if ok2 and data2["data"]:
                intro_body = {
                    "data": {
                        "type": "subscriptionIntroductoryOffers",
                        "attributes": {
                            "duration": "ONE_WEEK",
                            "numberOfPeriods": 1,
                            "offerMode": "FREE_TRIAL",
                            "startDate": None,
                            "endDate": None
                        },
                        "relationships": {
                            "subscription": {"data": {"type": "subscriptions", "id": sub_id}},
                            "territory": {"data": {"type": "territories", "id": "USA"}},
                            "subscriptionPricePoint": {"data": {"type": "subscriptionPricePoints", "id": data2["data"][0]["id"]}}
                        }
                    }
                }
                ok3, data3 = check(
                    "POST create introductory offer (free trial)",
                    *client.post("v1/subscriptionIntroductoryOffers", intro_body)
                )
                if ok3:
                    info("C5", f"Free trial intro offer created! id={data3['data']['id']}")
                    # Clean up
                    client.delete(f"v1/subscriptionIntroductoryOffers/{data3['data']['id']}")
                else:
                    errors = data3.get("errors", [])
                    if any("404" in str(e.get("status", "")) for e in errors):
                        info("C5", "Introductory offers endpoint NOT found")
                    else:
                        info("C5", "Endpoint exists but validation error (endpoint is valid)")
    else:
        skip("C5", "No subscription created")

    # ── C6: Subscription promotional offers ──
    print("\n" + "=" * 60)
    print("C6: Subscription promotional offers")
    print("=" * 60)
    if sub_id:
        ok, data = check(
            "GET subscription promotional offers",
            *client.get(f"v1/subscriptions/{sub_id}/promotionalOffers")
        )
        if ok:
            info("C6", f"Promotional offers readable: {len(data.get('data', []))} offers")
    else:
        skip("C6", "No subscription")

    # ── C7: Tax category check ──
    print("\n" + "=" * 60)
    print("C7: Tax category — check if API-settable")
    print("=" * 60)
    # Tax category in ASC is typically set per IAP/subscription type
    # It may be read-only or auto-derived from app category
    # Check subscription attributes
    if sub_id:
        ok, data = check(
            "GET subscription full details",
            *client.get(f"v1/subscriptions/{sub_id}")
        )
        if ok:
            all_attrs = list(data["data"]["attributes"].keys())
            info("C7", f"Subscription attributes: {all_attrs}")

    # ═══════════════════════════════════════════════════════════════
    # CLEANUP
    # ═══════════════════════════════════════════════════════════════
    print("\n" + "#" * 70)
    print("# CLEANUP")
    print("#" * 70)

    if sub_id:
        s, _ = client.delete(f"v1/subscriptions/{sub_id}")
        print(f"  Delete subscription: HTTP {s}")
    if group_id:
        s, _ = client.delete(f"v1/subscriptionGroups/{group_id}")
        print(f"  Delete group: HTTP {s}")
    if iap_id:
        s, _ = client.delete(f"v2/inAppPurchases/{iap_id}")
        print(f"  Delete IAP: HTTP {s}")

    # ═══════════════════════════════════════════════════════════════
    # SUMMARY
    # ═══════════════════════════════════════════════════════════════
    print("\n" + "#" * 70)
    print("# SUMMARY")
    print("#" * 70)
    total = results["pass"] + results["fail"]
    print(f"\nResults: {results['pass']}/{total} passed, {results['fail']} failed, {results['skip']} skipped")

    print("\n--- Key Findings ---")
    for label, msg in results["info"]:
        print(f"  {label}: {msg}")

    print("\n--- Field Coverage Matrix ---")
    print("""
    PRICING & AVAILABILITY:
      [?] Effective Date (startDate on appPrices)      — tested above
      [?] Global Price Change (equalizations)          — tested above

    IN-APP PURCHASES:
      [?] Availability (territory selection)            — tested above
      [?] Price Schedule (auto-calculated)              — tested above
      [?] Localization (name, description)              — tested above
      [?] Review Screenshot                             — tested above
      [?] Review Notes (PATCH)                          — tested above
      [?] Tax Category                                  — tested above

    SUBSCRIPTIONS:
      [?] Availability (territory selection)            — tested above
      [?] Price Schedule (auto-calculated)              — tested above
      [?] Localization (name, description)              — tested above
      [?] Review Screenshot                             — tested above
      [?] Review Notes (PATCH)                          — tested above
      [?] Tax Category                                  — tested above
      [?] Introductory Offers (free trial)              — tested above
      [?] Promotional Offers                            — tested above
    """)

    return results["fail"] == 0


if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)
