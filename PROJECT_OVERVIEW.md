## Meon KYC Flow – Project Overview

This document explains how the Meon KYC app works end‑to‑end: UI steps, APIs, and core architecture. It is written to help anyone understand and extend the project safely.

---

### 1. Tech Stack & High‑Level Architecture

- **Client**: Flutter app (Material 3, Provider for state management).
- **Entry**: `lib/main.dart` → `lib/app.dart` (sets up theme, routes via `go_router`).
- **State Management**:
  - `AppStore` (`lib/store/app_store.dart`) – holds workflow context, stepper data, user details, auth state.
  - `ConditionalFormNotifier` (`lib/hooks/conditional_form.dart`) – manages dynamic form fields, values, visibility, and validation.
- **Networking**:
  - `BaseAPI` and `ApiClient` (`lib/api/base_api.dart`, `lib/api/api_client.dart`) wrap `http` for GET/POST + logging.
  - `ApiInterceptor` handles token refresh on 401, retries, etc.
  - API base URL configured in `lib/config/env_config.dart`.
- **KYC Screens**:
  - Main KYC flow: `lib/pages/home_page.dart`.
  - Completed screen: `lib/pages/kyc_completed_page.dart`.
  - WebView based verification (Digilocker, eSign, etc.): `lib/pages/webview_page.dart`.
- **UI Components**:
  - Stepper: `lib/components/kyc_stepper_bar.dart`.
  - Layout wrapper: `lib/components/kyc_layout.dart`.
  - Dynamic form fields: `lib/components/form_field_widget.dart`.
  - Segments (trading preferences): `lib/components/segments_selection.dart`.
  - “Documents to keep Handy”: `lib/components/documents_handy_section.dart`.
  - OTP UI: `lib/components/otp_input.dart`, `lib/components/otp_verify_section.dart`.

---

### 2. Core Concepts

#### 2.1 Workflow, Context & Steps

- Backend defines a **workflow** (e.g. `bp_flow`) with multiple steps (mobile, email, PAN, bank, etc.).
- The app always works off two key pieces of information:
  - **`fields`** (unauthenticated) – structure of the workflow before login.
  - **`fieldsWithAuth`** (authenticated) – current step fields + context once the user has started KYC.
- `fieldsWithAuth['context']` contains:
  - `position` – current logical step key (e.g. `"mobile"`, `"mobile_otp"`, `"email"`, `"segments"`, `"kradetails"`).
  - `page` – structure for current page (fields, labels, metadata).
  - `design_template`, `workflow_key`, `index` / `step` – used for stepper and routing.

#### 2.2 Stepper & Dynamic Steps

- `AppStore.fetchStepperWorkflow(workflowName, workflowId)` calls:
  - `GET /kycadmin_getWorkflow/{workflowName}/{workflowId}` via `KycAPI.getStepperWorkflow()`.
- Response is normalized into ordered step labels by:
  - `AppStore.getStepperSteps()` → returns a list like:
    - `['mobile', 'mobile_otp', 'email', 'email_otp', 'segments', 'detailspan', 'kradetails', ...]`.
- `KycStepperBar`:
  - Uses `steps` + `currentIndex` to render:
    - Circle for each step (completed / active / upcoming).
    - Connector between steps:
      - **Normal state**: purple/grey line.
      - **Special rocket icon**: between **previous step** and **current step** connector (only for the connector immediately before the current index).
  - `AppStore.getCurrentStepIndex()` finds the appropriate index from `position` and `page.id`.

---

### 3. High‑Level User Flow

#### 3.1 Unauthenticated Start (Mobile → OTP)

1. **Launch / Start your KYC screen**
   - Route: `/${company}/${workflowName}` (e.g. `/mandotsecurities/bp_flow`).
   - `HomePage` loads **unauth fields** via `fetchWorkflowFields` and renders:
     - Hero title: “Start your KYC / or pickup where you left off”.
     - Mobile number field (`mobile` / `phone` / `mobile_number`).
     - Custom T&C checkbox.
     - Aadhaar note.
     - “Send OTP” button (enabled only when:
       - 10‑digit mobile starting 6–9
       - T&C accepted).
     - “Documents to keep Handy” card (visible for step index 0).

2. **Send OTP (mobile)**
   - Handler: `_handleSubmit(false)` in `home_page.dart`.
   - API: `POST /api/get-user/{company}/{workflowName}`.
   - Payload includes:
     - `mobile` / `phone` / `mobile_number` and other visible fields.
   - On success:
     - Stores tokens (`access_token`, `refresh_token`) in `StorageService`.
     - Sets auth success flags and user step.
     - Fetches **authenticated fieldsWithAuth** via:
       - `AppStore.fetchWorkflowFieldsWithAuth(company, workflowName, '')`.
     - Navigates back to same route; now KYC continues as **authenticated** user.

3. **Mobile OTP verify (`position: mobile_otp`)**
   - `fieldsWithAuth.context.position = 'mobile_otp'`.
   - UI:
     - OTP input (single field, max length 6, **Verify enabled when ≥ 4 digits**).
     - Text showing “OTP sent to +91 XXXXX...”.
     - “Edit mobile” link (goes back to mobile step).
     - Aadhaar note; “Documents to keep Handy” section is still shown (step index 1).
   - Verify:
     - `OtpVerifySection` calls `_handleCommonSubmit(false)` with `otp` field set.
     - API: `POST /api/kyc-post-v2/{company}/{workflowName}/{pathSegment}`.
       - `pathSegment` built from `context.page.name + page.id` (e.g. `mobile_otp2`).
       - Payload includes `otp` and `change_mobile`.
       - **Important**: For OTP verify steps (`position == mobile_otp || email_otp`) the app **does not** send `save: true`.
   - Error handling:
     - Any non‑success response is parsed by `_errorMessageFromResponse(statusCode, body)` to show backend message like “Invalid OTP”.

4. **Email & Email OTP**
   - Same structure:
     - `position: 'email'` → email input + optional “Sign in with Google”.
     - `position: 'email_otp'` → OTP input; Verify when ≥ 4 digits.
   - Submit & Verify use `_handleCommonSubmit` with underlying `/api/kyc-post-v2/.../emailX` and `email_otpY` endpoints.
   - “Documents to keep Handy” visible for these two steps as well (step index 2 and 3).

#### 3.2 Authenticated Form Steps (PAN, Segments, KRA, Bank, etc.)

Once mobile/email are verified, each subsequent step works as:

1. **Context**
   - `fieldsWithAuth.context.position` set to current logical step (e.g. `segments`, `detailspan`, `kradetails`, `pan`, `bank`, …).
   - `fieldsWithAuth.context.page.fields` contains array of field definitions:
     - `name`, `displayName`, `type`, `validation`, `mandatory`, `values`, `fieldShow`, etc.

2. **Dynamic Field Rendering**
   - `_getActiveFields(store)` extracts the current page from context.
   - `_buildForm(...)`:
     - Filters visible fields by conditional flow (`ConditionalFormNotifier.fieldVisibility`).
     - Passes each field to `FormFieldWidget`.
   - `FormFieldWidget`:
     - Chooses widget type based on `type` (`text`, `number`, `file`, `date`, `otp`, etc.).
     - Applies proper keyboard type, max length, icons, labels.
     - For file uploads, integrates with `_prepareFormData` and multipart uploads.

3. **Validation**
   - `ConditionalFormNotifier.validate()` calls:
     - `validateFormWithConditions` in `lib/utils/field_validators.dart`.
     - Per‑field rules:
       - `mobile`, `email`, `pan`, `ifsc`, `bank` (account number), `aadhaar`, `pincode`, generic `number`, `minLength`, `maxLength`.
   - If validation fails:
     - Shows first error via toast.
     - Keeps user on same step.

4. **Submit (Generic)**
   - For most steps, submit button uses `_handleCommonSubmit(skipValidation: false)`:
     - Builds `pathSegment` from `context.page`.
     - `data = await _prepareFormData(false)` – merges current form values.
     - **For non‑OTP authenticated submissions**:
       - Adds `data['save'] = true` (helps backend track saves).
     - Checks `saveFilesAPI` flag from `context.page.data`.
       - If true and there are file fields: uploads files to `/api/upload_files_new` first, then posts JSON without file blobs.
       - Otherwise, either uses multipart/form-data for file steps, or JSON for others.
   - Endpoint:
     - `POST /api/kyc-post-v2/{company}/{workflowName}/{pathSegment}`.
   - Response:
     - On `2xx` and `body['success'] == true`:
       - Saves updated `step` to `StorageService`.
       - Resets form.
       - Calls `fetchWorkflowFieldsWithAuth` to get new context & possibly redirect.
       - Applies redirect logic (e.g. to `/webview` for external flows).
     - On error:
       - Uses `_errorMessageFromResponse` to show an appropriate message.

#### 3.3 Special Steps

- **Segments (Trading Preferences)** – `position: 'segments'`
  - Renders `SegmentsSelection` instead of generic form.
  - NSE/BSE + MF/MTF selection with custom checkboxes.
  - “View Brokerage Plan” opens `BrokeragePlanDialog.show()`.
  - “Next” triggers `_handleCommonSubmit` or `_handleSubmit` as appropriate.

- **WebView‑driven steps** – e.g. Digilocker, eSign
  - `webview_page.dart` uses `flutter_inappwebview`:
    - Intercepts URLs for completion or deep‑links.
    - Handles external UPI / app schemes via `_handleExternalUrl`.
    - On completion, passes `completionParams` back so that next `get-context` reflects step completion.

- **KYC Completed Page**
  - Uses `KycCompletedPage` with a static “KYC Completed” layout plus dynamic “Completed Steps” list (from backend or default).

---

### 4. Layout, Stepper & UI Rules

#### 4.1 Layout Wrapper (`KycLayout`)

For most screens (inside `HomePage`):

- `KycLayout` handles:
  - Optional top row (back/logout) – extremely thin.
  - Stepper (when `stepperSteps` is passed).
  - Scrollable content with max width 480 for good mobile/desktop layout.
  - Optional “Documents to keep Handy” section.
- On the **first screen** (Start your KYC):
  - When `skipScaffold == true` and title is the hero text, `KycLayout`:
    - Shows centered **STOXBOX logo** at top.
    - Then the hero title + first form card.

#### 4.2 Logout Placement

- `HomePage` owns the primary logout button:
  - Always shown at **top‑right**, above the stepper (for authenticated users).
  - Implemented as an `IconButton` in the `Scaffold` body, not inside the stepper.
  - Also used on **KycCompletedPage**.

#### 4.3 Stepper Behaviour

- Stepper uses dynamic steps from `AppStore.getStepperSteps()` or `KycStepperBar.defaultSteps`.
- Each step:
  - Completed: purple circle with white checkmark.
  - Active: purple circle with step number, bold label.
  - Upcoming: gray circle and label.
- Connector between steps:
  - **By default**: thin line.
  - **Special rocket connector**:
    - Shown **only** on the connector immediately **before the current step** index.
    - Useful for visually highlighting the transition into the current step.

#### 4.4 “Documents to keep Handy” Rules

- **Visible only on first 4 steps** of the stepper:
  1. Enter Mobile
  2. Mobile OTP
  3. Email
  4. Email OTP
- Implementation:
  - `showDocumentsSection = (stepperIndex <= 3);`
  - Passed into `KycLayout.showDocumentsSection`.
  - When false, `DocumentsHandySection` is not rendered at all.

---

### 5. API Summary

#### 5.1 Authentication & User Context

- `POST /api/get-user/{company}/{workflowName}`
  - Used on first (mobile) step to send OTP and retrieve tokens.
  - Response includes:
    - `access_token`, `refresh_token`, `success`, `msg`, `position`, etc.
  - App stores tokens in `StorageService` and marks authenticated.

- `POST /api/user/logout`
  - Called by `_handleLogout`.
  - Then app clears all tokens, resets `AppStore`, and reloads workflow unauthenticated.

#### 5.2 Workflow & Steps

- `GET /api/get-workflow-details/{company}/{workflowName}` (wrapped in `fetchWorkflowFields`)
  - Returns initial workflow structure before login.

- `POST /api/get-user-context/{company}/{workflowName}` (wrapped inside `fetchWorkflowFieldsWithAuth`)
  - Returns `fieldsWithAuth` with context and current page fields.

- `POST /api/kyc-post-v2/{company}/{workflowName}/{pathSegment}`
  - Unified **submit/verify endpoint** for each authenticated step.
  - Payload:
    - Current form field values (OTP, PAN, bank details, etc.).
    - `save: true` for non‑OTP authenticated forms.
  - Response:
    - `success`, `msg`, `step`, optional redirects/URLs for next actions.

- `GET /kycadmin_getWorkflow/{workflowName}/{workflowId}`
  - Returns stepper steps metadata (for display).

#### 5.3 File Uploads

- `POST /api/upload_files_new`
  - When `context.page.saveFilesAPI == true`, app:
    - Extracts file fields.
    - Uploads each file via this endpoint, then sends JSON without blobs to `kyc-post-v2`.

- `POST /api/kyc-post-v2/...` (multipart branch)
  - For file steps when `saveFilesAPI == false`, app uses multipart form with file parts plus textual fields.

#### 5.4 Bank IFSC Lookup

- `POST /get_bank_address_by_ifsc`
  - Called by `_fetchBankDetailsByIfsc`.
  - Auto‑fills bank name/branch fields on bank step; only allowed when `position` indicates bank screen.

---

### 5A. Focus: `get-context` & `kyc-post-v2` (How the core APIs work)

These two APIs drive almost the entire KYC engine. Think of them as:

- **`kyc-post-v2`** → “Main submit / verify API” (writes data, advances step).
- **`get-user-context` (get‑context)** → “Tell me which step I am on now, and which fields to show” (reads data + context).

#### 5A.1 `kyc-post-v2` – How data is posted

When user taps **Submit / Next / Verify OTP** on any authenticated step:

1. `HomePage._handleCommonSubmit(skipValidation: false)` runs:
   - Builds `pathSegment` from `context.page.name + page.id`, e.g.:
     - `mobile_otp2`, `email3`, `segments5`, `kradetails8`, etc.
   - Prepares `data` from the current form (`_prepareFormData`).
   - For **normal authenticated forms** (non‑OTP):
     - Adds `data['save'] = true` so backend knows it’s a save/submit action.
   - For **OTP verify steps** (`position == 'mobile_otp'` or `'email_otp'`):
     - **Does NOT** send `save: true` (backend focuses purely on OTP validation).

2. Handles files if needed:
   - If page has `saveFilesAPI == true`:
     - Extracts file fields → uploads them via `/api/upload_files_new`.
     - Removes file blobs from `data` and then calls `kyc-post-v2` with pure JSON.
   - Else if there are files:
     - Uses multipart request to `kyc-post-v2` (file parts + other fields).
   - Else:
     - Simple JSON `POST`.

3. Makes the request:
   - `POST /api/kyc-post-v2/{company}/{workflowName}/{pathSegment}`
   - Body contains:
     - All visible / editable fields for that step (OTP, PAN, bank details, etc.).
     - Possibly `save: true` for confirmed saves.

4. Interprets the response:
   - Safely parses JSON (or falls back to raw text) and checks:
     - `statusCode in 200..299` **and** `body['success'] == true` → **success path**:
       - Saves next `step` to storage (`StorageService.setUserStep`).
       - Resets local form.
       - Immediately calls **get‑context** to load the next step (see below).
       - Applies redirect logic (e.g. open WebView step).
     - Otherwise → **error path**:
       - Extracts message via `_errorMessageFromResponse`:
         - Looks for `msg`, `message`, `error`, `detail`, or uses body text.
       - Shows that error to user (toast), stays on same step.

In short: **`kyc-post-v2` = “send current step data → backend validates/saves → tells us to move forward or show error.”**

#### 5A.2 `get-user-context` (“get‑context”) – How the app knows which step to show

After login and after almost every successful `kyc-post-v2` call:

1. `AppStore.fetchWorkflowFieldsWithAuth(company, workflowName, completionParams)` runs:
   - Makes:
     - `POST /api/get-user-context/{company}/{workflowName}`
   - Body includes:
     - Auth tokens (via headers).
     - Optional **completion params** (e.g. from WebView/eSign flows) so backend can mark a step as completed.

2. Backend responds with a **fresh context**:
   - `fieldsWithAuth` map containing:
     - `context.position` – logical current step (e.g. `"segments"`, `"kradetails"`, `"pan"`, `"bank"`).
     - `context.page.fields` – list of field definitions for that step.
     - `context.page.data` – label, metadata, flags (e.g., `saveFilesAPI`, `design_template`).
     - Possibly redirect info (e.g. open a WebView URL).

3. `AppStore` updates internal state:
   - Stores `fieldsWithAuth`, `currentPosition`, and other flags.
   - `ConditionalFormNotifier` is updated with new fields and default values.

4. UI rebuilds based on new context:
   - `HomePage` reads `fieldsWithAuth.context.position` to decide what to render:
     - If `position == 'mobile'` → show mobile login card.
     - If `position == 'mobile_otp'` → show mobile OTP verify UI.
     - If `position == 'segments'` → show `SegmentsSelection`.
     - If `position == 'webview'`‑like → navigate to `WebViewPage`, etc.
   - `KycStepperBar` uses `AppStore.getCurrentStepIndex()` (from `position` + `page.id`) to highlight the correct step and place the rocket connector.

So the **loop per step** is:

1. Render form based on last `get-user-context`.
2. User fills fields and taps Submit / Verify.
3. Call `kyc-post-v2` for this step.
4. On success, immediately call `get-user-context` again.
5. New context tells the app which step to show next.

This tight cycle between **`kyc-post-v2` (write)** and **`get-user-context` (read)** is what keeps the UI, stepper, and backend workflow perfectly in sync.

---

### 6. Where to Look for What

- **Main KYC Flow**: `lib/pages/home_page.dart`
  - Routing, initial load, form rendering, submit handlers.
- **Dynamic Forms & Validation**:
  - `lib/hooks/conditional_form.dart`
  - `lib/components/form_field_widget.dart`
  - `lib/utils/field_validators.dart`
- **Stepper & Layout**:
  - `lib/components/kyc_stepper_bar.dart`
  - `lib/components/kyc_layout.dart`
- **Design‑specific Components**:
  - `lib/components/documents_handy_section.dart`
  - `lib/components/segments_selection.dart`
  - `lib/components/kyc_note_box.dart`
- **Networking & Tokens**:
  - `lib/api/base_api.dart`
  - `lib/api/api_client.dart`
  - `lib/api/interceptor.dart`
  - `lib/services/storage_service.dart`

This overview should give you a clear mental model of how the app progresses step‑by‑step, how APIs are orchestrated, and where to plug in new business logic or screens safely.

