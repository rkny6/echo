import Testing
@testable import echo

struct AssistantMessageSequencePlannerTests {
    @Test
    func parserExtractsStructuredMessagesFromJSONPayload() {
        let parser = AssistantResponsePayloadParser()

        let response = parser.parse("""
        {
          "messages": [
            { "content": "我刚看到你的消息。", "delay_ms": 0, "notify": true },
            { "content": "你先别急，我们慢慢说。", "delay_ms": 900 }
          ]
        }
        """)

        #expect(response?.messages.count == 2)
        #expect(response?.messages[0].content == "我刚看到你的消息。")
        #expect(response?.messages[0].delayMilliseconds == 0)
        #expect(response?.messages[0].shouldNotify == true)
        #expect(response?.messages[1].content == "你先别急，我们慢慢说。")
        #expect(response?.messages[1].delayMilliseconds == 900)
    }

    @Test
    func parserHandlesCodeFencedJSONPayload() {
        let parser = AssistantResponsePayloadParser()

        let response = parser.parse("""
        ```json
        {
          "messages": [
            "先喝点水。",
            { "content": "我陪你一起理一下。", "delay_ms": 700 }
          ]
        }
        ```
        """)

        #expect(response?.messages.map(\.content) == [
            "先喝点水。",
            "我陪你一起理一下。"
        ])
    }


    @Test
    func segmenterSplitsNaturalChineseSentences() {
        let segmenter = AssistantMessageSegmenter(
            targetLength: 20,
            secondaryTargetLength: 12,
            minimumMergeLength: 4
        )

        let segments = segmenter.split("我刚到家。先去洗个手，再来和你说。你今天怎么样？")

        #expect(segments == [
            "我刚到家。",
            "先去洗个手，再来和你说。",
            "你今天怎么样？"
        ])
    }

    @Test
    func segmenterKeepsDecimalNumbersIntact() {
        let segmenter = AssistantMessageSegmenter(targetLength: 18, secondaryTargetLength: 10)

        let segments = segmenter.split("体温 36.5 度，已经好多了。晚点再聊。")

        #expect(segments.count == 2)
        #expect(segments[0].contains("36.5"))
        #expect(segments == [
            "体温 36.5 度，已经好多了。",
            "晚点再聊。"
        ])
    }

    @Test
    func segmenterSplitsLongClauseHeavyMessage() {
        let segmenter = AssistantMessageSegmenter(
            targetLength: 14,
            secondaryTargetLength: 8,
            minimumMergeLength: 4
        )

        let input = "我今天有点忙，不过已经在路上了，等我到家再慢慢和你说，别担心"
        let segments = segmenter.split(input)

        #expect(segments.count >= 2)
        #expect(segments.joined() == input)
    }

    @Test
    func plannerOnlyNotifiesOnFirstSegmentAndPreservesOrder() {
        let planner = AssistantMessageSequencePlanner(
            segmenter: AssistantMessageSegmenter(
                targetLength: 16,
                secondaryTargetLength: 10,
                minimumMergeLength: 4
            )
        )

        let plan = planner.plan(from: "我刚看到你的消息。先让我抱抱你。我们一条一条说。")

        #expect(plan.count == 3)
        #expect(plan[0].content == "我刚看到你的消息。")
        #expect(plan[1].content == "先让我抱抱你。")
        #expect(plan[2].content == "我们一条一条说。")
        #expect(plan[0].shouldNotify)
        #expect(!plan[1].shouldNotify)
        #expect(!plan[2].shouldNotify)
        #expect(plan[0].delayFromPrevious == 0)
        #expect(plan[1].delayFromPrevious > 0)
        #expect(plan[2].delayFromPrevious > 0)
    }

    @Test
    func plannerPrefersStructuredMessagesAndUsesProvidedDelay() {
        let planner = AssistantMessageSequencePlanner()

        let plan = planner.plan(from: """
        {
          "messages": [
            { "content": "我在。", "delay_ms": 0 },
            { "content": "你先告诉我最难受的是哪一块。", "delay_ms": 1200, "notify": false }
          ]
        }
        """)

        #expect(plan.count == 2)
        #expect(plan[0].content == "我在。")
        #expect(plan[0].delayFromPrevious == 0)
        #expect(plan[0].shouldNotify)
        #expect(plan[1].content == "你先告诉我最难受的是哪一块。")
        #expect(abs(plan[1].delayFromPrevious - 1.2) < 0.001)
        #expect(!plan[1].shouldNotify)
    }

    @Test
    func plannerRenderedTextUsesStructuredMessageContents() {
        let planner = AssistantMessageSequencePlanner()

        let text = planner.renderedText(from: """
        {
          "messages": [
            { "content": "先别急。", "delay_ms": 0 },
            { "content": "我在这里。", "delay_ms": 800 }
          ]
        }
        """)

        #expect(text == "先别急。 我在这里。")
    }

    @Test
    func parserCapsStructuredMessagesAtThree() {
        let parser = AssistantResponsePayloadParser()

        let response = parser.parse("""
        {
          "messages": [
            { "content": "第一条" },
            { "content": "第二条" },
            { "content": "第三条" },
            { "content": "第四条应被截断" }
          ]
        }
        """)

        #expect(response?.messages.map(\.content) == [
            "第一条",
            "第二条",
            "第三条"
        ])
    }

    @Test
    func plannerFallbackCapsPlainTextSegmentsAtThreeWithoutDroppingTail() {
        let planner = AssistantMessageSequencePlanner(
            segmenter: AssistantMessageSegmenter(
                targetLength: 4,
                secondaryTargetLength: 4,
                minimumMergeLength: 1
            )
        )

        let plan = planner.plan(from: "一句。两句。三句。四句。五句。")

        #expect(plan.count == 3)
        #expect(plan[0].content == "一句。")
        #expect(plan[1].content == "两句。")
        // Overflow past the cap is merged into the final bubble.
        #expect(plan[2].content.contains("三句。"))
        #expect(plan[2].content.contains("四句。"))
        #expect(plan[2].content.contains("五句。"))
        #expect(plan.map(\.content).joined() == "一句。两句。三句。四句。五句。")
    }
}
