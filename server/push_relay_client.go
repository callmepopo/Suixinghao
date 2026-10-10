package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

func relayEnabled() bool {
	for _, suffix := range []string{"", "_SANDBOX", "_PRODUCTION"} {
		if os.Getenv("VOICE_WEB_PUSH_RELAY_URL"+suffix) != "" || os.Getenv("VOICE_WEB_PUSH_RELAY_KEY_FILE"+suffix) != "" {
			return true
		}
	}
	return false
}

// An explicit environment route never borrows credentials from another route.
// The original pair remains the fallback for single-environment deployments.
func relayRoute(environment string) (string, string, error) {
	if environment != "sandbox" && environment != "production" {
		return "", "", errors.New("invalid relay environment")
	}
	suffix := "_" + strings.ToUpper(environment)
	endpoint := os.Getenv("VOICE_WEB_PUSH_RELAY_URL" + suffix)
	credential := os.Getenv("VOICE_WEB_PUSH_RELAY_KEY_FILE" + suffix)
	if endpoint == "" && credential == "" {
		endpoint = os.Getenv("VOICE_WEB_PUSH_RELAY_URL")
		credential = os.Getenv("VOICE_WEB_PUSH_RELAY_KEY_FILE")
	}
	if endpoint == "" || credential == "" {
		return "", "", errors.New("incomplete relay route")
	}
	return endpoint, credential, nil
}

var relayHTTPClient = &http.Client{Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}

func forwardRelay(ctx context.Context, input relayPush) (int, string, error) {
	endpoint, credential, err := relayRoute(input.Environment)
	if err != nil {
		return 0, "", err
	}
	u, err := url.Parse(endpoint)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return 0, "", errors.New("invalid relay HTTPS endpoint")
	}
	b, err := os.ReadFile(credential)
	if err != nil {
		return 0, "", errors.New("relay credential unavailable")
	}
	key := strings.TrimSpace(string(b))
	if relayCredential("Bearer "+key) == "" {
		return 0, "", errors.New("invalid relay credential")
	}
	payload, _ := json.Marshal(input)
	req, err := http.NewRequestWithContext(ctx, "POST", u.String(), bytes.NewReader(payload))
	if err != nil {
		return 0, "", errors.New("invalid relay request")
	}
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	response, err := relayHTTPClient.Do(req)
	if err != nil {
		return 0, "", errors.New("relay delivery unavailable")
	}
	defer response.Body.Close()
	if response.StatusCode != 200 && response.StatusCode != 502 {
		return 0, "", errors.New("relay refused request")
	}
	var result relayResult
	if json.NewDecoder(io.LimitReader(response.Body, 1024)).Decode(&result) != nil {
		return 0, "", errors.New("invalid relay response")
	}
	if response.StatusCode == 200 && result.Status != 200 {
		return 0, "", errors.New("invalid relay success")
	}
	if response.StatusCode == 502 && result.Status == 200 {
		return 0, "", errors.New("invalid relay failure")
	}
	switch result.Reason {
	case "", "BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic", "InvalidProviderToken", "ExpiredProviderToken", "TopicDisallowed", "BadTopic", "TooManyRequests", "ProviderUnavailable", "ProviderRejected":
	default:
		result.Reason = "ProviderRejected"
	}
	return result.Status, result.Reason, nil
}
func dispatchVoIP(ctx context.Context, device voipDevice, callID string) (int, string, error) {
	if relayEnabled() {
		environment := "production"
		if device.Sandbox {
			environment = "sandbox"
		}
		return forwardRelay(ctx, relayPush{Kind: "voip", Token: device.Token, Environment: environment, CallID: callID})
	}
	provider, err := providerFor(device.Sandbox)
	if err != nil {
		return 0, "", err
	}
	return provider.send(ctx, device, callID)
}
func dispatchSMS(ctx context.Context, device smsPushDevice) (int, string, error) {
	if relayEnabled() {
		environment := "production"
		if device.Sandbox {
			environment = "sandbox"
		}
		return forwardRelay(ctx, relayPush{Kind: "sms", Token: device.Token, Environment: environment})
	}
	provider, err := providerFor(device.Sandbox)
	if err != nil {
		return 0, "", err
	}
	return provider.sendSMSAlert(ctx, device)
}
