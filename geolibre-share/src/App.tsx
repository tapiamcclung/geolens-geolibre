import { useEffect, useState } from "react";
import {
  Show,
  SignInButton,
  SignUpButton,
  UserButton,
  useAuth,
} from "@clerk/react";
import { apiFetch } from "./api";

type MeResponse = Record<string, unknown>;

const projects = [
  {
    title: "Nepal Flash Floods",
    author: "@giswqs",
    views: "4.4K",
    category: "Disaster mapping",
    color: "mint",
    icon: "◈",
  },
  {
    title: "3D Tiles",
    author: "@giswqs",
    views: "9.2K",
    category: "3D geospatial",
    color: "blue",
    icon: "⬡",
  },
  {
    title: "Mars",
    author: "@giswqs",
    views: "148",
    category: "Planetary mapping",
    color: "orange",
    icon: "◎",
  },
  {
    title: "NYC Buildings & Subways",
    author: "@community",
    views: "2.1K",
    category: "Urban planning",
    color: "purple",
    icon: "⌘",
  },
];

export default function App() {
  const { isLoaded, isSignedIn, getToken } = useAuth();

  const [me, setMe] = useState<MeResponse | null>(null);
  const [apiError, setApiError] = useState("");
  const [apiLoading, setApiLoading] = useState(false);
  const [query, setQuery] = useState("");
/* 
  async function loadMe() {
    setApiLoading(true);
    setApiError("");

    try {
      const clerkToken = await getToken();

      if (!clerkToken) {
        throw new Error("No active Clerk session.");
      }

      const baseUrl = import.meta.env.VITE_API_URL?.replace(/\/+$/, "") || "";

      // 1. Exchange the Clerk JWT for a native GeoLibre access token
      const exchangeResponse = await fetch(`${baseUrl}/oauth/sso/callback`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${clerkToken}`,
        },
        body: JSON.stringify({ token: clerkToken }),
      });

      if (!exchangeResponse.ok) {
        const errorBody = await exchangeResponse.json().catch(() => ({}));
        throw new Error(
          errorBody.detail ||
            errorBody.error ||
            `Token exchange failed (HTTP ${exchangeResponse.status})`,
        );
      }

      const exchangeData = await exchangeResponse.json();
      const geoLibreToken = exchangeData.access_token || exchangeData.token;

      if (!geoLibreToken) {
        throw new Error("GeoLibre server did not return a session token.");
      }

      // 2. Persist GeoLibre session token locally
      sessionStorage.setItem("geolibre_access_token", geoLibreToken);

      // 3. Fetch authenticated profile from GeoLibre Server
      const result = await apiFetch<MeResponse>(
        "/api/users/me",
        geoLibreToken,
      );

      setMe(result);
    } catch (error) {
      setApiError(
        error instanceof Error
          ? error.message
          : "Could not connect to GeoLibre Server.",
      );
    } finally {
      setApiLoading(false);
    }
  } */

/*   async function loadMe() {
    setApiLoading(true);
    setApiError("");

    try {
      // 1. Get the live Clerk session JWT directly from Clerk React SDK
      const clerkToken = await getToken();

      if (!clerkToken) {
        throw new Error("No active Clerk session.");
      }

      // 2. Pass clerkToken directly to apiFetch (attaches Authorization: Bearer <clerkToken>)
      const result = await apiFetch<MeResponse>(
        "/api/users/me",
        clerkToken,
      );

      setMe(result);
    } catch (error) {
      setApiError(
        error instanceof Error
          ? error.message
          : "Could not connect to GeoLibre Server.",
      );
    } finally {
      setApiLoading(false);
    }
  } */

  async function loadMe() {
    setApiLoading(true);
    setApiError("");

    try {
      const clerkToken = await getToken();

      if (!clerkToken) {
        setMe(null);
        throw new Error("No active Clerk session token.");
      }

/*      const parts = clerkToken.split(".");
      const header = JSON.parse(atob(
        parts[0].replace(/-/g, "+").replace(/_/g, "/")
      ));
      console.log("Clerk JWT header:", header);
*/
      const parts = clerkToken.split(".");
      const payload = JSON.parse(
        atob(parts[1].replace(/-/g, "+").replace(/_/g, "/")),
      );

      console.log("Clerk JWT claims:", {
        iss: payload.iss,
        azp: payload.azp,
        subPresent: Boolean(payload.sub),
        exp: payload.exp,
      });
      const result = await apiFetch<MeResponse>(
        "/api/users/me",
        clerkToken,
      );

      setMe(result);
    } catch (error) {
      setApiError(
        error instanceof Error
          ? error.message
          : "Could not connect to GeoLibre Server.",
      );
    } finally {
      setApiLoading(false);
    }
  }

  async function testServer() {
    const baseUrl = import.meta.env.VITE_API_URL?.replace(/\/+$/, "");

    if (!baseUrl) {
      console.error("VITE_API_URL is missing");
      return;
    }

    try {
      const response = await fetch(`${baseUrl}/api/projects?limit=1`);
      const body = await response.text();

      console.log("Request URL:", `${baseUrl}/api/projects?limit=1`);
      console.log("HTTP status:", response.status);
      console.log("Response body:", body);
    } catch (error) {
      console.error("Network/CORS request failed:", error);
    }
  }


  function startGeoLibreOAuth() {
    const apiUrl = (
      import.meta.env.VITE_API_URL || ""
    ).replace(/\/+$/, "");

    if (!apiUrl) {
      setApiError("VITE_API_URL is not configured.");
      return;
    }

    const randomString = (length: number) => {
      const bytes = crypto.getRandomValues(
        new Uint8Array(length),
      );

      return Array.from(
        bytes,
        (byte) => String.fromCharCode(65 + (byte % 26)),
      ).join("");
    };

    const state = randomString(32);
    const verifier = randomString(64);

    sessionStorage.setItem("oauth_state", state);
    sessionStorage.setItem("oauth_code_verifier", verifier);

    const redirectUri =
      `${window.location.origin}/oauth-callback.html`;

    void crypto.subtle
      .digest(
        "SHA-256",
        new TextEncoder().encode(verifier),
      )
      .then((digest) => {
        const bytes = new Uint8Array(digest);
        let binary = "";

        for (const byte of bytes) {
          binary += String.fromCharCode(byte);
        }

        const challenge = btoa(binary)
          .replace(/\+/g, "-")
          .replace(/\//g, "_")
          .replace(/=+$/, "");

        const params = new URLSearchParams({
          response_type: "code",
          client_id: "geolibre-web",
          redirect_uri: redirectUri,
          scope:
            "read:projects write:projects share:public",
          state,
          code_challenge: challenge,
          code_challenge_method: "S256",
        });

        window.location.assign(
          `${apiUrl}/oauth/authorize?${params.toString()}`,
        );
      })
      .catch((error: unknown) => {
        sessionStorage.removeItem("oauth_state");
        sessionStorage.removeItem("oauth_code_verifier");

        setApiError(
          error instanceof Error
            ? error.message
            : "Unable to start GeoLibre authorization.",
        );
      });
  }


/*   useEffect(() => {
    if (!isLoaded || !isSignedIn) {
      setMe(null);
      return;
    }

    void loadMe();
    // Run when the Clerk session becomes available or changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isLoaded, isSignedIn, getToken]); */


  useEffect(() => {
    if (!isLoaded || !isSignedIn) {
      setMe(null);
      setApiError("");
      return;
    }

    //if (sessionStorage.getItem("geolibre_access_token")) {
      void loadMe();
    //}
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isLoaded, isSignedIn, getToken]);


  const filteredProjects = projects.filter((project) =>
    `${project.title} ${project.author} ${project.category}`
      .toLowerCase()
      .includes(query.toLowerCase()),
  );

  return (
    <div className="app-shell">
      <header className="topbar">
        <a className="brand" href="/">
          <span className="brand-mark">G</span>
          <span>
            Share<span className="brand-muted">.GeoLibre</span>
          </span>
        </a>

        <nav className="main-nav">
          <a className="nav-active" href="#explore">
            Explore
          </a>
          <a href="#featured">Projects</a>
          <a href="#about">About</a>
        </nav>

        <div className="account-actions">
          <Show when="signed-out">
            <SignInButton mode="modal">
              <button className="button button-light">Sign in</button>
            </SignInButton>
            <SignUpButton mode="modal">
              <button className="button button-green">Get started</button>
            </SignUpButton>
          </Show>

          <Show when="signed-in">
            <button
              className="button button-light"
              onClick={loadMe}
              disabled={apiLoading}
            >
              {apiLoading ? "Loading..." : "My account"}
            </button>
            <UserButton />
          </Show>
        </div>
      </header>

      <main>
        <section className="hero" id="explore">
          <div className="hero-copy">
            <div className="eyebrow">
              <span className="green-dot" />
              OPEN GEOSPATIAL PROJECTS
            </div>

            <h1>
              Share your maps.
              <br />
              <span>Explore the world.</span>
            </h1>

            <p>
              Upload your GeoLibre projects, share interactive maps, and discover
              geospatial work from the community.
            </p>

            <div className="hero-buttons">
              <a href="#featured" className="button button-green">
                Explore projects <span>→</span>
              </a>

              <Show when="signed-out">
                <SignUpButton mode="modal">
                  <button className="button button-light">
                    Join the community
                  </button>
                </SignUpButton>
              </Show>

              <Show when="signed-in">
                <button className="button button-light" onClick={loadMe}>
                  Check my connection
                </button>
              </Show>
            </div>
          </div>

          <div className="hero-art" aria-hidden="true">
            <div className="map-grid" />
            <div className="map-contour contour-one" />
            <div className="map-contour contour-two" />
            <div className="map-contour contour-three" />
            <div className="map-pin pin-one">+</div>
            <div className="map-pin pin-two">+</div>
            <div className="map-label">OPEN DATA · OPEN MAPS</div>
          </div>
        </section>

        <button onClick={testServer}>Test GeoLibre server</button>

        <section className="stats" aria-label="Community statistics">
          <article className="stat-card">
            <span className="stat-icon">▦</span>
            <div>
              <strong>370</strong>
              <span>Public projects</span>
            </div>
          </article>

          <article className="stat-card">
            <span className="stat-icon">♧</span>
            <div>
              <strong>154</strong>
              <span>Contributors</span>
            </div>
          </article>

          <article className="stat-card">
            <span className="stat-icon">▤</span>
            <div>
              <strong>5</strong>
              <span>Collections</span>
            </div>
          </article>

          <article className="stat-card stat-community">
            <span className="community-dot" />
            <div>
              <strong>Built for everyone</strong>
              <span>Open geospatial work</span>
            </div>
          </article>
        </section>

        {isLoaded && isSignedIn && (
          <section className="account-panel">
            <div>
              <span className="section-kicker">ACCOUNT CONNECTION</span>
              <h2>Your GeoLibre account</h2>
              <p>
                This panel calls your existing
                <code> GET /api/users/me </code> endpoint.
              </p>
            </div>

            <div className="connection-status">
              {apiLoading ? (
                <span>Connecting...</span>
              ) : apiError ? (
                <span className="error-text">Connection failed</span>
              ) : me ? (
                <span className="success-text">
                  <span className="green-dot" />
                  Connected
                </span>
              ) : (
                <span>Waiting for response</span>
              )}
            </div>
            
              <button
                className="button button-green"
                onClick={startGeoLibreOAuth}
              >
                Connect GeoLibre account
              </button>
            

            {apiError && (
              <div className="api-error" role="alert">
                <p>{apiError}</p>
                <button className="button button-light" onClick={loadMe}>
                  Retry
                </button>
              </div>
            )}

            {me && (
              <pre className="api-response">
                {JSON.stringify(me, null, 2)}
              </pre>
            )}
          </section>
        )}

        <section className="projects-section" id="featured">
          <div className="section-heading">
            <div>
              <span className="section-kicker">DISCOVER</span>
              <h2>Featured projects</h2>
              <p>Explore maps and projects shared by the community.</p>
            </div>

            <label className="search-box">
              <span aria-hidden="true">⌕</span>
              <input
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                placeholder="Search projects..."
                aria-label="Search projects"
              />
            </label>
          </div>

          <div className="project-grid">
            {filteredProjects.map((project) => (
              <article className="project-card" key={project.title}>
                <div className={`project-art art-${project.color}`}>
                  <span className="art-symbol">{project.icon}</span>
                  <span className="art-tag">GEOLIBRE</span>
                  <span className="art-orbit orbit-one" />
                  <span className="art-orbit orbit-two" />
                </div>

                <div className="project-info">
                  <span className="project-category">{project.category}</span>
                  <h3>{project.title}</h3>

                  <div className="project-meta">
                    <span>{project.author}</span>
                    <span>↗ {project.views} views</span>
                  </div>
                </div>
              </article>
            ))}
          </div>

          {filteredProjects.length === 0 && (
            <div className="empty-state">No projects match "{query}".</div>
          )}
        </section>

        <section className="about-strip" id="about">
          <div>
            <span className="section-kicker">MADE FOR MAP MAKERS</span>
            <h2>Your work deserves to be shared.</h2>
            <p>
              Build a map in GeoLibre, upload your project, and give others a
              way to explore it.
            </p>
          </div>
          <a href="#explore" className="button button-green">
            Explore the community →
          </a>
        </section>
      </main>

      <footer className="site-footer">
        <a className="brand" href="/">
          <span className="brand-mark">G</span>
          Share.GeoLibre
        </a>
        <span>Open geospatial work, shared with everyone.</span>
      </footer>
    </div>
  );
}