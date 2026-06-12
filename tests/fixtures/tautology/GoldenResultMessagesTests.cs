// GOOD: golden-value tests — expected side is an INDEPENDENT hardcoded literal,
// not a value read back from the class under test. If the message map is wrong,
// these tests FAIL. This is the correct pattern the lint must NOT flag.
using Xunit;
using FluentAssertions;

namespace Consumer.Tests
{
    public class GoldenResultMessagesTests
    {
        [Fact]
        public void GetMessage_ReturnsW0008Message()
        {
            // Expected is a hardcoded golden string — independent of ResultMessages.
            Assert.Equal("Session token status is missing or empty.", ResultMessages.GetMessage("W0008"));
        }

        [Fact]
        public void GetMessage_ReturnsW0001Message_Fluent()
        {
            ResultMessages.GetMessage("W0001").Should().Be("Channel identifier is not recognized.");
        }

        [Fact]
        public void GetMessage_ReturnsE1001Message()
        {
            Assert.Equal("Session token validation failed.", ResultMessages.GetMessage("E1001"));
        }

        [Fact]
        public void GetMessage_UnknownCode_ReturnsEmpty()
        {
            // string.Empty is lowercase 'string' — not a class-like token; and even
            // String.Empty would not intersect with ResultMessages on the other side.
            Assert.Equal(string.Empty, ResultMessages.GetMessage("ZZZZ"));
        }
    }
}
