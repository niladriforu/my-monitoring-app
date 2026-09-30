import React, { useEffect, useMemo, useState } from "react";
import { get } from "./api.js";
import { LAND, LAT_MAX, LAT_MIN, MAP_H, MAP_W, project } from "./land.js";

const fmtNum = (n) => n.toLocaleString("en-US");
const fmtUsd = (n) =>
  n.toLocaleString("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 });

const keyOf = (country, city) => `${country}|${city}`;

function radius(volume, maxVolume) {
  if (volume <= 0 || maxVolume <= 0) return 2.4;
  return 3.2 + Math.sqrt(volume / maxVolume) * 10;
}

export default function WorldMap() {
  const [data, setData] = useState(null);
  const [err, setErr] = useState(null);
  const [active, setActive] = useState(null);

  useEffect(() => {
    let alive = true;
    const run = () =>
      get("/api/geo")
        .then((d) => alive && (setData(d), setErr(null)))
        .catch((e) => alive && setErr(e.message));
    run();
    const id = setInterval(run, 3000);
    return () => {
      alive = false;
      clearInterval(id);
    };
  }, []);

  const cities = useMemo(() => {
    if (!data) return [];
    return data.countries.flatMap((country) =>
      country.cities.map((city) => ({ ...city, country: country.country }))
    );
  }, [data]);

  useEffect(() => {
    if (!data) return;
    setActive((current) => {
      const stillThere = cities.some((city) => keyOf(city.country, city.city) === current);
      if (stillThere) return current;
      const top = data.countries[0]?.cities[0];
      return top ? keyOf(data.countries[0].country, top.city) : null;
    });
  }, [data, cities]);

  if (err) return <div className="down">{err}</div>;
  if (!data) return <div className="dim">LOADING…</div>;

  const maxVolume = Math.max(1, ...cities.map((city) => city.volume));
  const totalVolume = data.countries.reduce((sum, country) => sum + country.volume, 0);
  const totalValue = data.countries.reduce((sum, country) => sum + country.value_usd, 0);
  const selected = cities.find((city) => keyOf(city.country, city.city) === active) || null;

  const graticule = [];
  for (let lon = -120; lon <= 180; lon += 60) {
    const [x] = project(lon, 0);
    graticule.push(<line key={`lon-${lon}`} x1={x} x2={x} y1={0} y2={MAP_H} className="graticule" />);
  }
  for (let lat = -30; lat <= 60; lat += 30) {
    if (lat <= LAT_MIN || lat >= LAT_MAX) continue;
    const [, y] = project(0, lat);
    graticule.push(<line key={`lat-${lat}`} x1={0} x2={MAP_W} y1={y} y2={y} className="graticule" />);
  }

  let tip = null;
  if (selected) {
    const [x, y] = project(selected.lon, selected.lat);
    const tipW = 176;
    const tipH = 54;
    let tx = x + 12;
    let ty = y - tipH / 2;
    if (tx + tipW > MAP_W - 6) tx = x - tipW - 12;
    ty = Math.max(6, Math.min(MAP_H - tipH - 6, ty));
    tip = (
      <g className="tip" transform={`translate(${tx} ${ty})`}>
        <rect width={tipW} height={tipH} rx="6" className="tip-bg" />
        <text x="10" y="16" className="tip-title">{selected.city}</text>
        <text x="10" y="30" className="tip-sub">{selected.country}</text>
        <text x="10" y="46" className="tip-num">
          {fmtNum(selected.volume)} received · {fmtUsd(selected.value_usd)}
        </text>
      </g>
    );
  }

  return (
    <div className="map-wrap">
      <div className="map-summary">
        <span><b>{fmtNum(totalVolume)}</b> received</span>
        <span><b>{fmtUsd(totalValue)}</b> value</span>
        <span className="dim">Dot size is volume. Value is converted to USD.</span>
      </div>
      <div className="map-layout">
        <div className="map-stage">
          <svg
            className="world"
            viewBox={`0 0 ${MAP_W} ${MAP_H}`}
            role="img"
            aria-label="World map of received transaction volume and value by city"
          >
            <rect width={MAP_W} height={MAP_H} className="ocean" />
            {graticule}
            <path d={LAND} className="land" fillRule="evenodd" />
            {[...cities].sort((a, b) => a.volume - b.volume).map((city) => {
              const [x, y] = project(city.lon, city.lat);
              const key = keyOf(city.country, city.city);
              const on = key === active;
              const r = radius(city.volume, maxVolume);
              return (
                <g
                  key={key}
                  className={on ? "place on" : "place"}
                  onMouseEnter={() => setActive(key)}
                  onClick={() => setActive(key)}
                >
                  <circle className="hit" cx={x} cy={y} r={Math.max(r, 8)} />
                  {on && <circle className="halo" cx={x} cy={y} r={r + 4} />}
                  <circle className="dot" cx={x} cy={y} r={r} />
                </g>
              );
            })}
            {tip}
          </svg>
        </div>
        <div className="map-list">
          <table className="geo">
            <thead>
              <tr>
                <th>PLACE</th>
                <th className="r">VOLUME</th>
                <th className="r">VALUE USD</th>
              </tr>
            </thead>
            <tbody>
              {data.countries.map((country) => (
                <React.Fragment key={country.country}>
                  <tr className="country">
                    <td>{country.country}</td>
                    <td className="r">{fmtNum(country.volume)}</td>
                    <td className="r">{fmtUsd(country.value_usd)}</td>
                  </tr>
                  {country.cities.map((city) => {
                    const key = keyOf(country.country, city.city);
                    const on = key === active;
                    return (
                      <tr
                        key={key}
                        className={on ? "city on" : "city"}
                        onMouseEnter={() => setActive(key)}
                        onClick={() => setActive(key)}
                      >
                        <td>{city.city}</td>
                        <td className="r">{fmtNum(city.volume)}</td>
                        <td className="r">{fmtUsd(city.value_usd)}</td>
                      </tr>
                    );
                  })}
                </React.Fragment>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}
