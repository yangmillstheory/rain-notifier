package main

import (
	"encoding/json"
	"fmt"
	"io/ioutil"
	"log"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/ses"
	"github.com/aws/aws-sdk-go/service/sns"
)

var (
	apiURL = os.Getenv("API_URL")
	apiKey = os.Getenv("API_KEY")
	lat    = os.Getenv("LAT")
	lng    = os.Getenv("LNG")

	topicArn = os.Getenv("TOPIC_ARN")
	emailTo  = os.Getenv("EMAIL_TO")

	fullURL    = fmt.Sprintf("%s/%s/%s,%s", apiURL, apiKey, lat, lng)
	httpClient = http.Client{}

	sess = session.New()

	sesClient = ses.New(sess)
	snsClient = sns.New(sess)
)

const (
	timeFormat = "Jan _2 3:04:05PM"
)

func init() {
	if apiURL == "" {
		log.Fatalf("Expected API_URL to be set.")
	} else if apiKey == "" {
		log.Fatalf("Expected API_KEY to be set.")
	} else if lat == "" {
		log.Fatal("Expected LAT to be set.")
	} else if lng == "" {
		log.Fatal("Expected LNG to be set.")
	}
	log.Printf("Initializing with API URL %s, latitude %s, longitude %s\n", apiURL, lat, lng)
}

type datum struct {
	// epoch time according to decodedResponse.Timezone
	Time              int64
	PrecipProbability float64
}

type decodedResponse struct {
	Timezone string
	Hourly   struct{ Data []datum }
}

type rainEvent struct {
	datum
	location *time.Location
}

func makeReq() *http.Request {
	req, err := http.NewRequest("GET", fullURL, nil)
	if err != nil {
		log.Fatalf("creating request: %v", err)
	}

	exclude := []string{"currently", "minutely", "daily", "alerts", "flags"}

	qs := url.Values{}
	qs.Add("exclude", strings.Join(exclude, ","))

	req.URL.RawQuery = qs.Encode()
	return req
}

// HandleRequest makes an authenticated call to the Dark Sky API.
//
// It parses the next working days' hours of weather data, and if there's some chance of precipitation,
// publishes to an SNS topic and sends an email via SES with the raw data used in the computation.
func HandleRequest() error {
	var (
		rsp decodedResponse
		err error
	)

	r, err := httpClient.Do(makeReq())
	if err != nil {
		return fmt.Errorf("making request: %v", err)
	}

	defer r.Body.Close()

	err = json.NewDecoder(r.Body).Decode(&rsp)
	if err != nil {
		body, _ := ioutil.ReadAll(r.Body)
		return fmt.Errorf("decoding response %s: %v", string(body), err)
	}

	location, err := time.LoadLocation(rsp.Timezone)
	if err != nil {
		return fmt.Errorf("loading timezone location %s: %v", rsp.Timezone, err)
	}

	sTime := time.Now().In(location).Add(
		time.Duration(10 * time.Hour))
	fTime := sTime.Add(
		time.Duration(14 * time.Hour))

	data := rsp.Hourly.Data

	sIndex := search(data, sTime)
	fIndex := search(data, fTime)

	log.Printf("Found index %d for time %s\n", sIndex, sTime.Format(timeFormat))
	log.Printf("Found index %d for time %s\n", fIndex, fTime.Format(timeFormat))

	var (
		rs []rainEvent
		j  int
	)

	for j, d := sIndex, data[j]; j <= fIndex; j++ {
		if d.PrecipProbability >= .4 {
			rs = append(rs, rainEvent{data[j], location})
		}
	}

	if len(rs) == 0 {
		log.Println("No rain to worry about :).")
		return nil
	}

	var (
		wg   sync.WaitGroup
		errc = make(chan error, 2)
		done = make(chan bool)
	)

	attachment, err := json.Marshal(rsp)
	if err != nil {
		return fmt.Errorf("creating attachment: %v", err)
	}

	message := makeMessage(rs)

	wg.Add(2)
	go email(message, attachment, &wg, errc)
	go publish(message, &wg, errc)
	go func() {
		wg.Wait()
		close(done)
		close(errc)
	}()

	select {
	case err = <-errc:
		return err
	case <-done:
		return nil
	}
}

func makeMessage(rs []rainEvent) string {
	var lines []string

	for _, r := range rs {
		when := time.Unix(r.Time, 0).In(r.location).Format(timeFormat)
		prob := 100 * r.PrecipProbability
		lines = append(lines, fmt.Sprintf("\\t%s\\t%f%%", when, prob))
	}

	return strings.Join(lines, "\\n")
}

func email(messageText string, attachment []byte, wg *sync.WaitGroup, errc chan<- error) {
	defer wg.Done()

	messageData := []byte(fmt.Sprintf("From: weather@yangmillstheory.com\\nTo: %s\\nSubject: It might rain soon!\\nMIME-Version: 1.0\\nContent-type: Multipart/Mixed; boundary=\"NextPart\"\\n\\n--NextPart\\nContent-Type: text/plain\\n\\n%s\\n\\n--NextPart\\nContent-Type: text/plain;\\nContent-Disposition: attachment; filename=\"data.json\"\\n\\n", emailTo, messageText))
	messageData = append(messageData, attachment...)
	messageData = append(messageData, []byte("\\n\\n--NextPart--")...)

	rawInput := &ses.SendRawEmailInput{
		RawMessage: &ses.RawMessage{Data: messageData},
	}

	log.Printf("Sending email to %s.", emailTo)

	_, err := sesClient.SendRawEmail(rawInput)
	if err != nil {
		errc <- fmt.Errorf("sending email: %v", err)
		return
	}

	log.Println("Email sent.")
}

func publish(messageText string, wg *sync.WaitGroup, errc chan<- error) {
	defer wg.Done()

	log.Printf("Publishing message to SNS topic %s\n", topicArn)

	_, err := snsClient.Publish(&sns.PublishInput{TopicArn: aws.String(topicArn), Message: aws.String(messageText)})
	if err != nil {
		errc <- err
		return
	}

	log.Println("Message published.")
}

// search does a binary search to return the first index in data
// for which the unix timestamp .Time is after t.
//
// this relies on data being sorted by .Time.
func search(data []datum, t time.Time) int {
	ts := t.Unix()
	cmp := func(i int) bool {
		return data[i].Time < ts
	}
	return sort.Search(len(data), cmp)
}

func main() {
	lambda.Start(HandleRequest)
}
