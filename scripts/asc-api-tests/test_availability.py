#!/usr/bin/env python3
"""Test IAP & subscription availability endpoints to determine correct approach for 'all countries'."""

import sys, os, json
sys.path.insert(0, os.path.dirname(__file__))
from asc_client import ASCClient, pp

APP_ID = "6760371146"  # FullSwift (com.blitz.fullswift)

def main():
    client = ASCClient()

    # Step 1: Fetch all territories
    print("=" * 60)
    print("STEP 1: Fetch all territories")
    print("=" * 60)
    all_territories = []
    url = "v1/territories?limit=200"
    while url:
        status, data = client.get(url)
        if status != 200:
            print(f"[FAIL] GET territories: HTTP {status}")
            pp(data)
            return
        all_territories.extend(data.get("data", []))
        next_link = data.get("links", {}).get("next")
        if next_link:
            # Strip base URL
            url = next_link.replace("https://api.appstoreconnect.apple.com/", "")
        else:
            url = None

    territory_ids = [t["id"] for t in all_territories]
    print(f"[OK] Found {len(territory_ids)} territories")
    print(f"  First 10: {territory_ids[:10]}")

    # Step 2: List existing IAPs
    print("\n" + "=" * 60)
    print("STEP 2: List existing IAPs")
    print("=" * 60)
    status, data = client.get(f"v2/inAppPurchases?filter[app]={APP_ID}&limit=50")
    if status != 200:
        # Try v1 endpoint
        status, data = client.get(f"v1/apps/{APP_ID}/inAppPurchases?limit=50")

    iaps = data.get("data", [])
    print(f"[OK] Found {len(iaps)} IAPs")
    iap_id = None
    for iap in iaps:
        attrs = iap["attributes"]
        print(f"  id={iap['id']} name={attrs.get('name')} productId={attrs.get('productId')} state={attrs.get('state')}")
        iap_id = iap["id"]  # Use last one

    if not iap_id:
        print("[SKIP] No IAPs found, cannot test availability")
        return

    # Step 3: Check current IAP availability
    print("\n" + "=" * 60)
    print(f"STEP 3: Check current IAP availability for {iap_id}")
    print("=" * 60)
    status, data = client.get(f"v2/inAppPurchases/{iap_id}/inAppPurchaseAvailability?include=availableTerritories&limit[availableTerritories]=200")
    print(f"  HTTP {status}")
    if status == 200:
        avail_data = data["data"]
        avail_attrs = avail_data.get("attributes", {})
        included = data.get("included", [])
        print(f"  availableInNewTerritories: {avail_attrs.get('availableInNewTerritories')}")
        print(f"  territories included: {len(included)}")
        if included:
            inc_ids = [i["id"] for i in included[:10]]
            print(f"  first 10: {inc_ids}")
        print("[INFO] Availability already exists — may need PATCH or DELETE+POST to change")
        # Try full response
        pp(avail_data)
    elif status == 404:
        print("[INFO] No availability set — need to POST")
    else:
        print("[WARN] Unexpected status")
        pp(data)

    # Step 4: Try to POST IAP availability with ALL territories + availableInNewTerritories=true
    print("\n" + "=" * 60)
    print("STEP 4: POST IAP availability (all territories)")
    print("=" * 60)

    territory_data = [{"type": "territories", "id": tid} for tid in territory_ids]

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
                    "data": territory_data
                }
            }
        }
    }

    status, data = client.post("v1/inAppPurchaseAvailabilities", avail_body)
    print(f"  HTTP {status}")
    if 200 <= status < 300:
        print("[PASS] IAP availability set to all territories!")
        avail_attrs = data.get("data", {}).get("attributes", {})
        print(f"  availableInNewTerritories: {avail_attrs.get('availableInNewTerritories')}")
    else:
        for err in data.get("errors", []):
            print(f"  Error: {err.get('detail', err.get('title', '?'))}")

        # If it failed because availability already exists, try a different approach
        if status == 409:
            print("\n[INFO] Conflict — availability already exists. Trying PATCH approach...")
            # First get the availability ID
            status2, data2 = client.get(f"v2/inAppPurchases/{iap_id}/inAppPurchaseAvailability")
            if status2 == 200:
                avail_id = data2["data"]["id"]
                print(f"  Existing availability ID: {avail_id}")
                # Try PATCH
                patch_body = {
                    "data": {
                        "type": "inAppPurchaseAvailabilities",
                        "id": avail_id,
                        "attributes": {
                            "availableInNewTerritories": True
                        },
                        "relationships": {
                            "availableTerritories": {
                                "data": territory_data
                            }
                        }
                    }
                }
                status3, data3 = client.patch(f"v1/inAppPurchaseAvailabilities/{avail_id}", patch_body)
                print(f"  PATCH HTTP {status3}")
                if 200 <= status3 < 300:
                    print("[PASS] IAP availability updated via PATCH!")
                else:
                    for err in data3.get("errors", []):
                        print(f"    Error: {err.get('detail', err.get('title', '?'))}")

    # Step 5: Verify
    print("\n" + "=" * 60)
    print("STEP 5: Verify IAP availability after set")
    print("=" * 60)
    status, data = client.get(f"v2/inAppPurchases/{iap_id}/inAppPurchaseAvailability?include=availableTerritories&limit[availableTerritories]=200")
    if status == 200:
        avail_data = data["data"]
        avail_attrs = avail_data.get("attributes", {})
        included = data.get("included", [])
        print(f"  availableInNewTerritories: {avail_attrs.get('availableInNewTerritories')}")
        print(f"  territories: {len(included)}")
        print("[PASS] Availability is set!")
    else:
        print(f"  HTTP {status}")
        pp(data)

    # Step 6: Check subscriptions too
    print("\n" + "=" * 60)
    print("STEP 6: Check subscription availability")
    print("=" * 60)
    status, data = client.get(f"v1/apps/{APP_ID}/subscriptionGroups?limit=50")
    if status == 200:
        groups = data.get("data", [])
        print(f"  Found {len(groups)} subscription groups")
        for g in groups:
            gid = g["id"]
            gname = g["attributes"].get("referenceName", "?")
            print(f"  Group: {gname} (id={gid})")

            # List subs in group
            s_status, s_data = client.get(f"v1/subscriptionGroups/{gid}/subscriptions?limit=50")
            if s_status == 200:
                subs = s_data.get("data", [])
                for sub in subs:
                    sub_id = sub["id"]
                    sub_name = sub["attributes"].get("name", "?")
                    print(f"    Sub: {sub_name} (id={sub_id})")

                    # Check availability
                    av_status, av_data = client.get(f"v1/subscriptions/{sub_id}/subscriptionAvailability?include=availableTerritories&limit[availableTerritories]=5")
                    if av_status == 200:
                        av_attrs = av_data["data"].get("attributes", {})
                        av_count = len(av_data.get("included", []))
                        print(f"      availableInNewTerritories: {av_attrs.get('availableInNewTerritories')}")
                        print(f"      territory sample: {av_count}")
                    elif av_status == 404:
                        print(f"      [NO AVAILABILITY SET]")

                        # Try to set it
                        sub_avail_body = {
                            "data": {
                                "type": "subscriptionAvailabilities",
                                "attributes": {
                                    "availableInNewTerritories": True
                                },
                                "relationships": {
                                    "subscription": {
                                        "data": {"type": "subscriptions", "id": sub_id}
                                    },
                                    "availableTerritories": {
                                        "data": territory_data
                                    }
                                }
                            }
                        }
                        post_status, post_data = client.post("v1/subscriptionAvailabilities", sub_avail_body)
                        print(f"      POST availability: HTTP {post_status}")
                        if 200 <= post_status < 300:
                            print(f"      [PASS] Subscription availability set!")
                        else:
                            for err in post_data.get("errors", []):
                                print(f"        Error: {err.get('detail', err.get('title', '?'))}")
                    else:
                        print(f"      HTTP {av_status}")

    print("\n" + "=" * 60)
    print("DONE")
    print("=" * 60)

if __name__ == "__main__":
    main()
