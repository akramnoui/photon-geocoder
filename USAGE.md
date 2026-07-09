# Photon usage guide (consumers)

| | |
|---|---|
| Base URL | `http://10.137.64.165` (SRVLH-GEO-A1, Nginx LB over 3 Photon nodes) |
| Protocol | **HTTP only, port 80**. The old `https://10.137.64.165` is retired: update old scripts |
| Auth | none, internal network only |
| Coverage | Europe + Brazil + Argentina (OpenStreetMap data) |
| Freshness | snapshot; refreshed only when the index is rebuilt. `GET /status` returns the `import_date` |
| Format | GeoJSON `FeatureCollection`; coordinates are always `[longitude, latitude]` |

Reference: [github.com/komoot/photon](https://github.com/komoot/photon).

## 1. Free-text query (primary)

Concatenate the address fields you have (house number, street, postcode, city) into a
single `q` string, URL-encoded, and always pass the country as an ISO 3166-1 alpha-2
code. The `countrycode` filter is what keeps a Porto address from matching in Brazil
(it can be repeated to allow several countries).

```
GET /api?q={housenumber} {street}, {postcode} {city}&countrycode={CC}&limit=1
```

```bash
curl 'http://10.137.64.165/api?q=170+Avenida+da+Boavista,+4050-115+Porto&countrycode=PT&limit=1'
```

> Migration note: the retired HTTPS deployment ran an older Photon build whose `/api`
> rejected `countrycode` with `400 Unknown query parameter`. If you get that error,
> you are still hitting the old stack; switch to `http://` and this base URL.

## 2. Structured query (fallback)

If the free-text query returns **no match** (`"features": []`), retry on the
structured endpoint with the fields split out. `postcode` and `countrycode` are the
minimum; add whatever else you have.

```
GET /structured?housenumber={n}&street={street}&postcode={postcode}&city={city}&countrycode={CC}&limit=1
```

```bash
curl 'http://10.137.64.165/structured?street=Avenida+da+Boavista&housenumber=170&postcode=4050-115&city=Porto&countrycode=PT&limit=1'
```

Accepted fields: `countrycode`, `state`, `county`, `city`, `postcode`, `district`,
`housenumber`, `street`.

Recommended client logic:

```
result = GET /api?q=...&countrycode=CC&limit=1
if result.features is empty:
    result = GET /structured?postcode=...&countrycode=CC&...&limit=1
if result.features is empty:
    address is not geocodable, stop
```

## Construire la requête (FR)

Comment passer d'un enregistrement adresse à la requête Photon :

1. **Champs du texte libre `q`** : `adresse, code postal, ville`, dans cet ordre,
   joints par `", "`. Omettre les champs vides et les artefacts de données
   (`nan`, `none`, `<na>`, `.`, `*`, `-`) : ne jamais les envoyer tels quels.
2. **Le pays ne va PAS dans le texte libre.** Il passe uniquement par le paramètre
   `countrycode`, en **ISO 3166-1 alpha-2** (`FR`, `PT`, `DE`, `GB`, `BR`...).
3. **URL-encoder** la valeur de `q` (espaces, accents, apostrophes).
4. Ajouter `limit=1` pour géocoder une adresse unique.

Exemple : l'enregistrement `route de thionville / 57050 / woippy / France` devient :

```
GET /api?q=route%20de%20thionville%2C%2057050%2C%20woippy&countrycode=FR&limit=1
```

En cas de `"features": []`, rejouer en structuré avec les mêmes champs éclatés
(`street`, `postcode`, `city`) et le même `countrycode` (section 2).

## 3. Reverse geocoding

Coordinates to nearest address:

```bash
curl 'http://10.137.64.165/reverse?lon=-8.6291&lat=41.1579&limit=1'
```

## Reading the response

```json
{
  "features": [{
    "geometry": { "coordinates": [-8.6291, 41.1579], "type": "Point" },
    "properties": {
      "name": "...", "housenumber": "170", "street": "Avenida da Boavista",
      "postcode": "4050-115", "city": "Porto", "country": "Portugal",
      "countrycode": "PT", "osm_id": 123456, "osm_type": "W",
      "osm_key": "building", "osm_value": "yes", "type": "house",
      "extent": [-8.6301, 41.1585, -8.6281, 41.1573]
    }
  }]
}
```

- Take `features[0]`; `geometry.coordinates` is `[lon, lat]`, **longitude first**.
- `properties.type` is the match precision: `house` > `street` > `district` >
  `city` > `county` > `state` > `country`. If you asked for a full address and got
  `type: city`, Photon only matched the city: decide whether that is good enough
  for your use case before consuming the coordinates.
- `extent` is the feature's bounding box (`[minLon, maxLat, maxLon, minLat]`),
  useful to detect very coarse matches (a whole city vs a building).
- Empty `features` = no match. There is no error status for "not found": a 200 with
  an empty list is the normal answer.

## Other parameters

| Param | Endpoints | Use |
|---|---|---|
| `limit` | all | number of results; use `1` for one address, max out around 10 |
| `lang` | all | label language: `en`, `fr`, `es`, `pt`, `de`, `it` (default: local names) |
| `lat` + `lon` | `/api` | bias ranking towards a point (e.g. the depot) without excluding the rest |
| `bbox` | `/api` | hard filter to a box: `minLon,minLat,maxLon,maxLat` |
| `osm_tag` | `/api` | filter by OSM tag, e.g. `osm_tag=amenity:pharmacy`, negate with `!` |
| `layer` | `/api` | restrict result types, e.g. `layer=house&layer=street` |

## Operational notes

- Requests are load-balanced over 3 nodes; a node failure is absorbed automatically.
- The LB cuts connections after **90 s** (you will never wait that long: a healthy
  query answers in tens of ms; treat multi-second latency as an incident).
- No rate limiting is enforced. For bulk geocoding, prefer a few parallel workers
  over an unbounded burst, and keep `limit` small.
- Health check for monitoring: `GET /status` (also shows the data's `import_date`).
- For debugging only, a node can be queried directly on `:2322`
  (e.g. `http://10.137.64.166:2322/api?...`), bypassing the LB.
