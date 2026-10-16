//const API = "https://share.dfu.etu.geoint.mx";
const API = import.meta.env.VITE_API_URL;
const OAUTH_CLIENT_ID = "geolibre-web";

const OAUTH_REDIRECT_URI = `${window.location.origin}/oauth-callback.html`;

const OAUTH_SCOPE = "read:projects write:projects share:public manage:sessions";

const $ = (id) => document.getElementById(id);


/* -------------------------------------------------------
   Messages
------------------------------------------------------- */

function showMessage(text, type = "error") {
  const el = $("message");

  el.textContent = text;
  el.className = `message ${type}`;
  el.hidden = false;
}

function clearMessage() {
  const el = $("message");

  el.hidden = true;
  el.textContent = "";
}


/* -------------------------------------------------------
   Loading state
------------------------------------------------------- */

function setButtonLoading(button, loading) {
  if (!button) {
    return;
  }

  button.classList.toggle("loading", loading);
  button.disabled = loading;

  if (loading) {
    button.setAttribute("aria-busy", "true");
  } else {
    button.removeAttribute("aria-busy");
  }
}


/* -------------------------------------------------------
   UI state
------------------------------------------------------- */

function setLoggedIn(account) {
  $("loginForm").hidden = true;
  $("signupForm").hidden = true;

  $("loginTab").hidden = true;
  $("signupTab").hidden = true;

  $("account").hidden = false;

  $("accountName").textContent =
    account?.username ||
    account?.email ||
    "your account";
}

function setLoggedOut() {
  $("loginForm").hidden = false;
  $("signupForm").hidden = true;

  $("loginTab").hidden = false;
  $("signupTab").hidden = false;

  $("loginTab").classList.add("active");
  $("loginTab").setAttribute("aria-selected", "true");

  $("signupTab").classList.remove("active");
  $("signupTab").setAttribute("aria-selected", "false");

  $("account").hidden = true;
}


/* -------------------------------------------------------
   API helper
------------------------------------------------------- */

/*async function api(path, options = {}) {
  const token = sessionStorage.getItem("geolibre_access_token");

  const headers = {
    "Content-Type": "application/json",
    ...(options.headers || {})
  };

  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  const response = await fetch(`${API}${path}`, {
    ...options,
    headers
  });

  let body = null;

  try {
    body = await response.json();
  } catch {
    // Response was not JSON.
  }

  if (!response.ok) {
    const error =
      body?.detail ||
      body?.error ||
      `Request failed (${response.status})`;

    throw new Error(error);
  }

  return body;
}*/
export async function api(
  path: string, 
  options: RequestInit = {}
) { 
  const token = sessionStorage.getItem(
    "geolibre_access_token"
  );
  
  const headers = new Headers(options.headers);
  headers.set("Content-Type", "application/json");
  
  if (token) { 
    headers.set("Authorization", `Bearer ${token}`);
  }
  const response = await fetch(`${API}${path}`, {
    ...options, headers,
  });
  let body: any = null;
  try { 
    body = await response.json();
  } catch {
    // Response wasn't JSON.
  } 
  
  if (!response.ok) {
    throw new Error(
      body?.detail ||
      body?.error ||
      `Request failed (${response.status})`
    );
  }
  return body;
}

/* -------------------------------------------------------
   Sign up
------------------------------------------------------- */

$("signupForm").addEventListener(
  "submit",
  async (event) => {
    event.preventDefault();

    clearMessage();

    const button = $("signupButton");

    setButtonLoading(button, true);

    const username =
      $("signupUsername")
        .value
        .trim()
        .toLowerCase();

    const email =
      $("signupEmail")
        .value
        .trim();

    const password =
      $("signupPassword").value;

    const password2 =
      $("signupPassword2").value;

    if (password !== password2) {
      showMessage("Passwords do not match.");

      setButtonLoading(button, false);

      return;
    }

    try {
      const result = await api(
        "/api/accounts",
        {
          method: "POST",

          body: JSON.stringify({
            username,
            email: email || null,
            password
          })
        }
      );

      if (result.token) {
        /*localStorage.setItem(
          "geolibre_access_token",
          result.token
        );*/
        sessionStorage.setItem(
          "geolibre_access_token",
          result.token
        );
      }

      showMessage(
        "Account created successfully.",
        "success"
      );

      setLoggedIn(result.account);

    } catch (error) {

      showMessage(error.message);

    } finally {

      setButtonLoading(button, false);

    }
  }
);


/* -------------------------------------------------------
   Sign in
------------------------------------------------------- */

$("loginForm").addEventListener(
  "submit",
  async (event) => {
    event.preventDefault();

    clearMessage();

    const button = $("loginButton");

    setButtonLoading(button, true);

    const username =
      $("loginUsername")
        .value
        .trim()
        .toLowerCase();

    const password =
      $("loginPassword").value;

    try {
      const result = await api(
        "/api/auth/token",
        {
          method: "POST",

          body: JSON.stringify({
            username,
            password
          })
        }
      );

      if (!result.token) {
        throw new Error(
          "Server did not return an access token."
        );
      }

      /*localStorage.setItem(
        "geolibre_access_token",
        result.token
      );*/
      sessionStorage.setItem(
          "geolibre_access_token",
          result.token
        );

      showMessage(
        "Signed in successfully.",
        "success"
      );

      setLoggedIn(result.account);

    } catch (error) {

      showMessage(error.message);

    } finally {

      setButtonLoading(button, false);

    }
  }
);


/* -------------------------------------------------------
   OAuth
------------------------------------------------------- */

$("continueButton").addEventListener(
  "click",
  startOAuth
);

function startOAuth() {
  const state = randomString(32);
  const verifier = randomString(64);
  sessionStorage.setItem("oauth_state", state);
  sessionStorage.setItem("oauth_code_verifier", verifier);
  sha256Base64Url(verifier)
    .then((challenge) => {
      const params = new URLSearchParams({
        response_type: "code",
        client_id: OAUTH_CLIENT_ID,
        redirect_uri: OAUTH_REDIRECT_URI,
        scope: OAUTH_SCOPE,
        state,
        code_challenge: challenge,
        code_challenge_method: "S256"
      });
      window.location.assign(
        `${API}/oauth/authorize?${params.toString()}`
      );
    })
    .catch((error) => {
      sessionStorage.removeItem("oauth_state");
      sessionStorage.removeItem("oauth_code_verifier");
      
      showMessage(error.message || "Unable to start OAuth.");
    });
  }


/* -------------------------------------------------------
   Random string
------------------------------------------------------- */

function randomString(length) {
  const bytes =
    new Uint8Array(length);

  crypto.getRandomValues(bytes);

  return Array.from(
    bytes,
    (byte) =>
      String.fromCharCode(
        65 + (byte % 26)
      )
  ).join("");
}


/* -------------------------------------------------------
   SHA-256 / PKCE
------------------------------------------------------- */

async function sha256Base64Url(value) {
  const data =
    new TextEncoder().encode(value);

  const digest =
    await crypto.subtle.digest(
      "SHA-256",
      data
    );

  const bytes =
    new Uint8Array(digest);

  let binary = "";

  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }

  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}


/* -------------------------------------------------------
   Sign out
------------------------------------------------------- */

$("logoutButton").addEventListener(
  "click",
  () => {
    /*localStorage.removeItem(
      "geolibre_access_token"
    );*/
    sessionStorage.removeItem(
      "geolibre_access_token"
    );

    setLoggedOut();
    clearMessage();
  }
);


/* -------------------------------------------------------
   Restore existing session
------------------------------------------------------- */

(async function restoreSession() {
  const token =
    /*localStorage.getItem(
      "geolibre_access_token"
    );*/
    sessionStorage.getItem(
      "geolibre_access_token"
    );

  if (!token) {
    setLoggedOut();
    return;
  }

  try {
    const result =
      await api("/api/users/me");

    setLoggedIn(
      result.user
    );

  } catch {

    localStorage.removeItem(
      "geolibre_access_token"
    );
    sessionStorage.removeItem(
      "geolibre_access_token"
    );

    setLoggedOut();
  }
})();


/* -------------------------------------------------------
   Tabs
------------------------------------------------------- */

$("loginTab").addEventListener(
  "click",
  () => {
    clearMessage();

    $("loginTab")
      .classList.add("active");

    $("loginTab")
      .setAttribute("aria-selected", "true");

    $("signupTab")
      .classList.remove("active");

    $("signupTab")
      .setAttribute("aria-selected", "false");

    $("loginForm").hidden = false;
    $("signupForm").hidden = true;
  }
);

$("signupTab").addEventListener(
  "click",
  () => {
    clearMessage();

    $("signupTab")
      .classList.add("active");

    $("signupTab")
      .setAttribute("aria-selected", "true");

    $("loginTab")
      .classList.remove("active");

    $("loginTab")
      .setAttribute("aria-selected", "false");

    $("loginForm").hidden = true;
    $("signupForm").hidden = false;
  }
);