// BAD: tautological tests — expected values are read from the SAME class under
// test (ResultMessages). If the message map is wrong, these tests still pass.
// Models the live exhibit from the SessionToken migration (PR #95): a generated
// ResultMessagesTests asserted the buggy message map against the map's own values.
using Xunit;
using FluentAssertions;

namespace Consumer.Tests
{
    public class TautologicalResultMessagesTests
    {
        [Fact]
        public void GetMessage_ReturnsW0008Message()
        {
            // TAUTOLOGICAL_ASSERTION: expected side reads ResultMessages.W0008 —
            // the class under test's own constant. MUST be flagged.
            Assert.Equal(ResultMessages.W0008, ResultMessages.GetMessage("W0008"));
        }

        [Fact]
        public void GetMessage_ReturnsE1001Message_Fluent()
        {
            // TAUTOLOGICAL_ASSERTION, fluent shape: same class on both sides of
            // .Should().Be(). MUST be flagged.
            ResultMessages.GetMessage("E1001").Should().Be(ResultMessages.E1001);
        }

        [Fact]
        public void GetMessage_ReturnsW0001Message_VarIndirection()
        {
            // DOCUMENTED MISS (false-negative bound: var-indirection): expected is
            // read into a local on a PRIOR line, so the single-line lexical lint
            // cannot connect the two. Must NOT be flagged (pins the known bound).
            var expected = ResultMessages.W0001;
            Assert.Equal(expected, ResultMessages.GetMessage("W0001"));
        }

        [Fact]
        public void GetMessage_ReturnsW0002Message_CrossLine()
        {
            // DOCUMENTED MISS (false-negative bound: cross-line arguments): the
            // assertion's arguments span lines, so the single-line lexical lint
            // sees no same-line intersection. Must NOT be flagged (pins the bound).
            Assert.Equal(
                ResultMessages.W0002,
                ResultMessages.GetMessage("W0002"));
        }
    }
}
