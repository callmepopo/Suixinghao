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
	return os.Getenv("VOICE_WEB_PUSH_RELAY_URL") != "" || os.Getenv("VOICE_WEB_PUSH_RELAY_KEY_FILE") != ""
}

var relayHTTPClient = &http.Client{Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}

func forwardRelay(ctx context.Context, input relayPush) (int, string, error) {
	u, err := url.Parse(os.Getenv("VOICE_WEB_PUSH_RELAY_URL"))
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return 0, "", errors.New("invalid relay HTTPS endpoint")
	}
	b, err := os.ReadFile(os.Getenv("VOICE_WEB_PUSH_RELAY_KEY_FILE"))
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
