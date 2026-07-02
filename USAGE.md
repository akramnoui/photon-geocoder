# Photon usage guide (consumers)

Base URL: `http://SRVLH-GEO-A1` (load balancer, port 80). No authentication, internal
network only. All responses are GeoJSON `FeatureCollection`; coordinates are
`[longitude, latitude]`.

Reference: [github.com/komoot/photon](https://github.com/komoot/photon).

## 1. Free-text query (primary)

Concatenate the address fields you have (street, house number, postcode, city) into a
single `q` string, and always pass the country as an ISO 3166-1 alpha-2 code:

```
GET /api?q={housenumber} {street}, {postcode} {city}&countrycode={CC}&limit=1
```

```bash
curl 'http://SRVLH-GEO-A1/api?q=170+Avenida+da+Boavista,+4050-115+Porto&countrycode=PT&limit=1'
```

## 2. Structured query (fallback)

If the free-text query returns **no match** (`"features": []`), retry on the
structured endpoint with the fields split out. `postcode` and `countrycode` are the
minimum; add the rest when available:

```
GET /structured?housenumber={n}&street={street}&postcode={postcode}&city={city}&countrycode={CC}&limit=1
```

```bash
curl 'http://SRVLH-GEO-A1/structured?street=Avenida+da+Boavista&housenumber=170&postcode=4050-115&city=Porto&countrycode=PT&limit=1'
```

## Reading the response

```json
{
  "features": [{
    "geometry": { "coordinates": [-8.6291, 41.1579], "type": "Point" },
    "properties": {
      "name": "...", "housenumber": "170", "street": "Avenida da Boavista",
      "postcode": "4050-115", "city": "Porto", "countrycode": "PT",
      "osm_id": 123456, "type": "house"
    }
  }]
}
```

- Take `features[0]`; `geometry.coordinates` is `[lon, lat]` (in that order).
- `properties.type` tells the match precision: `house` > `street` > `locality`/`city`.
- Empty `features` = no match: apply the fallback above, then give up.

## Other parameters

| Param | Use |
|---|---|
| `limit` | number of results (use `1` for geocoding a single address) |
| `lang` | language of the labels (`en`, `fr`, `es`, `pt`, `de`, `it`) |
| `lat` / `lon` | bias results towards a location (optional) |

Health check: `GET /status`.
